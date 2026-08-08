#!/usr/bin/env bash
# careful-guard.sh — PreToolUse hook for Bash commands
# Detects destructive operations and triggers confirmation prompt.
# Emits the PreToolUse hookSpecificOutput schema (permissionDecision "ask") to warn,
# or {} to allow. The old top-level {"permissionDecision":...} shape was ignored by
# the harness, leaving the guard silently inert.
#
# Ported from garrytan/gstack careful/bin/check-careful.sh (MIT)
# Stripped: telemetry, kubectl/docker patterns (not relevant for solo dev)
# Added: git clean -f detection
set -euo pipefail

# Advisory guard: on any internal error, fail OPEN (allow) rather than blocking
# every Bash command. This is a warn/ask guard, not a fail-closed review gate.
trap 'echo "{}"; exit 0' ERR

INPUT=$(cat)
CMD=""
AUTO_MODE=0

# --- Auto mode: stand down on what the classifier already owns ---
# In `auto`, a classifier model judges every non-read action and blocks force-push,
# git reset --hard, checkout/restore ., clean -fd, and "irreversibly destroying files
# that existed before the session" — against the ACTUAL request, which a regex cannot
# do. SQL DROP/TRUNCATE is the one pattern the classifier does not name, so it stays
# live in EVERY mode.
#
# BE PRECISE ABOUT WHAT THIS BUYS. The stand-down is belt-and-braces plus a real cost
# win; it is NOT what prevents a duplicate prompt, because in `auto` there was never
# a prompt to duplicate. Measured across a live session per mode (hooks and settings
# load at session START, so this can only be probed from a FRESH session in the mode
# under test — probing in-session reads the old config and returns a false negative):
#
#     mode      guard "ask"   hook block   operator prompt
#     auto      DISCARDED     honored      suppressed
#     bypass    HONORED       honored      delivered
#     default   HONORED       honored      delivered
#
# So in `auto`, emitting `ask` and standing down are behaviourally identical. What the
# stand-down actually saves is the work: the python rm scanner (and its interpreter
# spawn) is skipped on every Bash call. The load-bearing half of this block is the
# other direction — `bypassPermissions` is where the guard's `ask` IS honored and no
# classifier exists, so nothing there may ever stand down.
#
# `bypassPermissions` gets no exemption: it has no classifier at all, so this guard is
# the only thing left besides the rm -rf / and rm -rf ~ circuit breaker.
#
# EXTERNAL DEPENDENCY (CodeRabbit, PR #543): this stand-down's safety hinges on
# Anthropic's `auto`-mode classifier continuing to block exactly these patterns
# (force-push, reset --hard, checkout/restore ., clean -fd, pre-existing-file
# deletion) — a probabilistic model behavior this repo cannot verify or pin.
# Re-check tests/test-careful-guard-auto-mode.sh's six classifier-covered cases
# whenever the Claude Code version pin changes, not just at initial review.
#
# PARSED, never grepped off the raw JSON: `"permission_mode":"auto"` can also appear
# INSIDE tool_input.command, so a raw-text match would let a crafted command disarm
# the guard. No python3, unparseable input, or any other mode leaves AUTO_MODE=0 and
# every check runs — over-warning stays the safe direction.
# SINGLE PASS. The command extraction and the auto decision come from ONE python
# invocation. Two passes cost a second interpreter spawn on EVERY Bash command
# (measured by Codex on PR #543: ~1.54-1.61s vs ~1.02-1.06s at the parent commit,
# against the 3s budget hooks.json gives this whole guard) — and splitting them is
# also what let the two disagree (cubic, same PR): a malformed tool_input made
# python bail on the command while the raw-text grep fallback still produced one,
# so `auto` stood the guard down on a command python never validated. One parse
# cannot contradict itself.
#
# Prefer python for correct JSON parsing (escaped quotes, multiline commands);
# both tool_input and toolInput keys, dict or JSON-string payloads. The grep
# fallback below covers python being absent — AUTO_MODE stays 0 on that path.
if command -v python3 &>/dev/null; then
  # shellcheck disable=SC2016  # python source: $ / backticks must not expand in bash
  _GUARD_PAYLOAD=$(printf '%s' "$INPUT" | python3 -E -S -c '
import sys
# -E + -S + this scrub for the same reason the rm scanner below does it: `python3 -c`
# prepends the CWD to sys.path, so a repo shipping its own json.py would execute
# inside this hook -- and here it could emit the auto token and disarm the checks.
# -E also drops PYTHONPATH, which could otherwise smuggle the CWD back in as an
# ABSOLUTE path that this relative-only scrub would not catch.
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import json
try:
    d = json.loads(sys.stdin.read() or "{}")
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp or "{}")
    cmd = inp.get("command") if isinstance(inp, dict) else None
    shape_ok = isinstance(cmd, str)
    # Line 1 is the auto token; the command follows verbatim and MUST come last,
    # because it may itself be multiline. The mode is compared HERE rather than in
    # bash: $( ) strips trailing newlines, so a permission_mode of "auto\n" would
    # collapse to "auto" and stand the guard down. A non-str never equals "auto",
    # so this also subsumes an isinstance check.
    sys.stdout.write("1\n" if shape_ok and d.get("permission_mode") == "auto" else "0\n")
    if shape_ok:
        sys.stdout.write(cmd)
except Exception:
    pass
' 2>/dev/null || true)
  # $( ) stripped the trailing newline, so a token-only payload has no newline left.
  if [[ "$_GUARD_PAYLOAD" == *$'\n'* ]]; then
    [[ "${_GUARD_PAYLOAD%%$'\n'*}" == 1 ]] && AUTO_MODE=1
    CMD=${_GUARD_PAYLOAD#*$'\n'}
  elif [[ "$_GUARD_PAYLOAD" == 1 ]]; then
    AUTO_MODE=1
  fi
fi

# Grep fallback when Python is not available (AUTO_MODE stays 0 — see above)
if [[ -z "$CMD" ]]; then
  # Reset, do not merely leave at 0. The parse can SUCCEED and still land here:
  # a valid but EMPTY tool_input.command satisfies the shape check, so the token
  # may already be 1 while CMD is empty. The grep then takes the first "command"
  # match anywhere in the payload — possibly from OUTSIDE tool_input — and that
  # string was never validated by the parse the auto decision was made on.
  # Measured (coderabbitai + cubic, PR #543), before this reset:
  #   {"permission_mode":"auto","command":"rm -rf /etc","tool_input":{"command":""}}
  #   auto -> {} (allowed)   default -> ask
  # Whatever supplies CMD here did not come from the validated parse, so the auto
  # decision cannot apply to it: run every check.
  AUTO_MODE=0
  CMD=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//' || true)
fi

# No command extracted — allow
if [[ -z "$CMD" ]]; then
  echo '{}'
  exit 0
fi

CMD_LOWER=$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]')

# --- Recursive rm: judge EVERY rm in the chain, not just the last one ---
# `rm -rf /etc && rm -rf node_modules` must warn about /etc even though the last
# rm targets a safe artifact. The previous greedy sed stripped to the final rm,
# so only that one was ever judged, and a trailing safe rm also short-circuited
# every other check below (git reset --hard, DROP TABLE, ...).
# Segment splitting is delegated to gitcmd_detect.split_segments (quote-aware);
# the safe-artifact carve-out stays here because it is this guard's own policy.
# Prints "<rm> <truncate>": rm is exactly "unsafe" or "safe", truncate exactly
# "truncate" or "notruncate". ANY other output (including empty) means the
# scanner itself did not run, which falls through to the grep fallbacks below.
RM_VERDICT=""
TRUNC_VERDICT=""
SQL_VERDICT=""
SQLOP_VERDICT=""
SQLTAB_VERDICT=""
# Run the scanner whenever python3 is there, auto mode INCLUDED. Auto mode stands
# down the rm CLASSIFIER, not the whole parser — the SQL and coreutils checks
# below are deliberately ungated (see the note above the DROP arm), and gating the
# scanner on the mode quietly took their eyes away too: they fell through to the
# raw-grep fallbacks, and `psql -c TR"UNC"ATE\ users` walked past a check that the
# unquoted spelling fails. The stand-down is applied to RM_VERDICT alone, after
# the scan, so it stays a decision about one classifier rather than about sight.
if command -v python3 &>/dev/null; then
  _GUARD_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
  # shellcheck disable=SC2016  # python source: $-expansion must not happen in bash
  # ONE line, TWO verdicts: "<rm> <truncate>". Split below rather than spawning
  # a second interpreter — see the SINGLE PASS note at the top of the file.
  _SCAN_OUT=$(printf '%s' "$CMD" | PYTHONPATH="$_GUARD_LIB" python3 -S -c '
import sys
# Drop CWD from sys.path (python3 -c prepends it ahead of PYTHONPATH) so a
# repo-controlled gitcmd_detect.py or shadowed stdlib cannot run in the guard.
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import fnmatch
import re
import shlex
# _all_chunks is private but deliberately reused: it expands $(...), backticks
# and `bash -c` payloads recursively, so `bash -c "rm -rf /etc"` is still seen.
# Scanning only the literal command would miss every nested form.
from gitcmd_detect import split_segments, chunks_and_truncation

# Build artifacts a rebuild reproduces. `out` is Next.js static export (and the
# `distDir`/output convention generally): measured over ~/.claude/watch-hooks.log,
# `rm -rf out && npm run build` was 24% of ALL Bash permission prompts — the single
# largest interruption source, and every one of them regenerable. Matching is by
# BASENAME, same as every other entry here, so `output/` is untouched.
SAFE = {"node_modules", ".next", "dist", "__pycache__", ".cache",
        "build", ".turbo", "coverage", "target", "out"}

# `out` is the one SAFE name generic enough to be somebody real data: `./out` in
# a Next.js project is a build artifact, but `/important/out` is not, and this
# guard cannot tell them apart from the basename alone. So it is safe only as a
# RELATIVE target — the shape actually observed (`rm -rf out && npm run build`).
# An absolute or ~-anchored path falls through and warns.
SAFE_RELATIVE_ONLY = {"out"}


def is_safe(target):
    base = target.rstrip("/").rsplit("/", 1)[-1]
    if base not in SAFE:
        return False
    if base not in SAFE_RELATIVE_ONLY:
        return True
    # `out` clears ONLY as a bare name in the current directory — `out`, `./out`,
    # `out/`. Anything carrying a path falls through and warns: absolute, `~`,
    # `../out`, `sub/out`, and `$VAR/out` (unexpanded, so its target is unknown).
    # `cd /elsewhere && rm -rf out` still clears, because this guard cannot see
    # cwd — that residual is the pre-existing semantics of every SAFE entry
    # (`build`, `dist`, `target` behave identically), not something `out` adds.
    stripped = target.rstrip("/")
    if stripped.startswith("./"):
        stripped = stripped[2:]
    return stripped == base and "$" not in stripped


TRUNCATE_SET = frozenset(("truncate",))
RM_SET = frozenset(("rm",))

# EVERY bracket expression, not the ones whose inner grammar we recognise.
#
# This started as a POSIX-class rule, then had to grow to composite classes, and
# the next review found `[^x]`, `[[=e=]]` and `[[.e.]]` waiting behind those -
# the whole of the bash bracket grammar, arriving one spelling per round. That
# is the ladder this file has declined four times elsewhere, so decline it here
# too: a bracket expression matches EXACTLY ONE character whatever is inside it,
# so `?` is the faithful stand-in for all of them and fnmatch never has to
# implement a grammar it does not have. The cost is over-warn on a bracket that
# could not actually produce the name (`truncat[xyz]`), which is the direction
# this guard errs in everywhere else.
# `\\.` first: a bracket expression may contain an ESCAPED close, and
# stopping at it read `truncat[e\\]]` as a pattern that matches nothing.
#
# The alternatives must be DISJOINT. Written as `\\.|[^]]` they overlap on
# a backslash, which two branches can each consume - the classic
# catastrophic-backtracking shape, and on an UNTERMINATED bracket it is
# exponential: 22 repeated `\\a` pairs spent the whole 3s scan budget and
# the guard emitted no verdict at all, which the bash arm reads as "no
# python3" and answers with raw grep. Excluding the backslash from the
# second branch makes the match linear and the shape unreachable.
GLOB_BRACKET = re.compile(
    r"\[[!^]?\]?(?:\\.|\[[:.=][^]]*[:.=]\]|[^]\\])*\]")
# The wildcard ATOMS of a glob - what is left after removing them is the part
# that actually spells a name.
GLOB_ATOM = re.compile(r"\[[^]]*\]|[*?]")

REDIR_CUT = re.compile(r"[<>]")
EXPAND_CUT = re.compile(r"[$" + chr(96) + r"]")

# One level of `{a,b}` alternation, and the cap on how many literals it may
# produce before the word is treated as unreadable instead.
BRACE_SPLIT = re.compile(r"\{([^{}]*(?:,|\.\.)[^{}]*)\}")
BRACE_CAP = 256
BRACE_DEPTH = 8
# What a group too large, too deep, or too malformed to expand yields instead.
# It could produce ANY name, so it produces a form every caller matches: the
# command-word walks recognise the marker in _matches, and the embedded
# `truncate` is what the SQL-keyword regex reads. Returning the half-expanded
# form - or nothing at all - is a fail-OPEN, and it is what nine levels of
# `t{{{{{{{{{run,x},x},x},x},x},x},x},x},x}cate` walked straight through.
BRACE_OVERFLOW = "\x02truncate\x02"

TRUNCATE_WORD = re.compile(r"\btruncate\b")
TRUNCATE_TABLE = re.compile(r"\btruncate\s+table\b")

UNESCAPED_SPACE = re.compile(r"(?<!\\)\s+")
# Bash ANSI-C and locale quoting - a dollar sign immediately in front of a
# quote pair, as in the escape-processing and translation forms. shlex implements
# NEITHER, so it consumes the quote pair and leaves the `$` behind as an
# ordinary character: `tr$\x27un\x27cate` arrives as `tr$uncate`, which the
# command-word normaliser then cuts at the `$` and reads as `tr`. Bash reads
# the same word as `truncate`. Dropping the `$` in front of the very quote pair
# bash would consume is the one edit that makes the two agree - and it cannot
# unbalance the quoting, because the pair itself is left untouched.
ANSI_C_STRING = re.compile(r"\$\x27((?:[^\x27\\]|\\.)*)\x27")
ANSI_C_LOCALE = re.compile(r"\$(?=\x22)")


LINE_CONT = re.compile(r"\\\n")

# The bash ANSI-C escape grammar, in full. The RANGES are the bash ones, not
# the Python ones: one or two hex digits after x, one to four after u, one to
# eight after U, one to three octal. An escape outside this table is left as
# written, which is what bash does too.
ANSI_C_ESCAPE = re.compile(
    r"\\(?:([abeEfnrtv?" + chr(92) + chr(92) + chr(39) + chr(34) + r"])"
    r"|x([0-9a-fA-F]{1,2})"
    r"|u([0-9a-fA-F]{1,4})"
    r"|U([0-9a-fA-F]{1,8})"
    r"|c(.)"
    r"|([0-7]{1,3}))")
ANSI_C_SIMPLE = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f",
                 "n": "\n", "r": "\r", "t": "\t", "v": "\v", "?": "?",
                 chr(92): chr(92), chr(39): chr(39), chr(34): chr(34)}


def _ansi_c_char(m):
    """One ANSI-C escape as the CHARACTER bash would put in the word.

    A decoded NUL is kept here and cut in _fold_ansi_c, which TRUNCATES the
    decoded string at it - bash ends the value there, so a dollar-quoted
    truncate\\0junk is the word truncate, and a \\0 between trunc and ate leaves
    truncate as well. Keeping the byte spelled a name in no set at all, and
    every numeric form of the escape (\\0, \\x00, \\u0000, \\c@) reached it.
    """
    simple, hexits, u4, u8, ctrl, octits = m.groups()
    if simple is not None:
        return ANSI_C_SIMPLE[simple]
    try:
        if ctrl is not None:
            # `.upper()` is not length preserving - Python maps a lone `ss`
            # to two characters, and `ord()` on the pair raised a TypeError
            # that killed the whole scanner. Bash uppercases a BYTE, so a
            # character that does not have a single-character upper form is
            # taken as written.
            upper = ctrl.upper()
            got = chr(ord(upper if len(upper) == 1 else ctrl) ^ 0x40)
        elif octits is not None:
            got = chr(int(octits, 8) & 0xFF)
        else:
            got = chr(int(hexits or u4 or u8, 16))
    except (ValueError, OverflowError):
        return m.group(0)              # out of range: bash prints it as written
    return got


def _fold_ansi_c(text):
    """Bash quoting rewritten into the plain forms shlex understands.

    A LINE CONTINUATION goes first. Bash deletes a backslash-newline before it
    tokenises anything, so `trun\\<newline>cate` is the single word `truncate`
    - and every scanner here kept the newline and saw two halves that spell no
    name. Removing it inside single quotes too is the over-warn direction and
    costs a word that was never split in the first place.

    shlex implements NEITHER form. The locale form only drops the dollar. The
    escape form also DECODES, and that is the half a bare drop missed:
    `\x24\x27trunc\\x61te\x27` is the word `truncate`, but leaving the escape
    in place spells a name that is in no set at all. Decode, then re-quote so
    the result still tokenises to exactly one word.

    The decoding follows the BASH grammar rather than being handed to Python.
    That grammar is CLOSED - a fixed table plus four numeric forms - so writing
    it out is not the enumerate-the-spellings ladder; borrowing Python was,
    because the two disagree. Python demands exactly four digits after a short
    unicode escape and RAISES on the bash-legal `\\u74runcate`, whereupon the
    handler left the word undecoded and the command allowed.

    Fold BEFORE lowercasing. The escape yields a real character, so lowercasing
    the text first leaves that character in whatever case the escape named -
    `TRUNC\\x41TE` decoded to `truncAte` and matched nothing.
    """
    def _double_quote_map(text):
        """One pass: True at each offset that sits inside a double-quoted span.

        SINGLE quotes count, because a double quote inside them is ordinary
        text - `X=SQ"SQ` opens nothing, and toggling on it made the rest of the
        command look quoted, which switched the ANSI-C decoding off exactly
        where an attacker would want it off.

        Computed ONCE rather than rescanned per match: asking the question from
        offset zero for every ANSI-C string is quadratic, and 2,000 of them in
        one command spent the whole scan budget.
        """
        flags = [False] * (len(text) + 1)
        dq = sq = False
        i = 0
        while i < len(text):
            c = text[i]
            if c == chr(92) and not sq:
                flags[i] = dq
                if i + 1 < len(text):
                    flags[i + 1] = dq
                i += 2
                continue
            if c == chr(34) and not sq:
                dq = not dq
            elif c == chr(39) and not dq:
                sq = not sq
            flags[i] = dq
            i += 1
        flags[len(text)] = dq
        return flags

    _dq = _double_quote_map(text)

    def one(m):
        # Cut at the first decoded NUL: bash ENDS the value there, so
        # `truncate\\0junk` is the word `truncate` and not `truncatejunk`.
        # Inside DOUBLE quotes bash does NOT apply ANSI-C quoting - it prints
        # the dollar and the quotes literally - so decoding there invented a
        # command name the shell never runs. The quotes still stand in this
        # RAW text, which is the one place that state is still readable.
        if _dq[m.start()]:
            return m.group(0)
        decoded = ANSI_C_ESCAPE.sub(_ansi_c_char, m.group(1)).split("\x00", 1)[0]
        return shlex.quote(decoded)
    text = LINE_CONT.sub("", text)
    return ANSI_C_LOCALE.sub("", ANSI_C_STRING.sub(one, text))

# A simple expansion, removed so literal fragments either side can rejoin.
# The SPECIAL parameters belong here beside the named ones. They are the most
# reliably empty expansions bash has - a hook command runs with no positional
# arguments at all, so `trun$@cate` is simply `truncate` - and leaving them out
# meant the one form guaranteed to vanish was the one form never read. The set
# is the documented table (`@ * # ? - $ ! 0` and a digit), not a growing list.
# The BACKTICK substitution belongs beside `$( )`. It is the same construct in
# the older spelling, and leaving it out meant the older spelling was the one
# that rejoined nothing: an empty `trun`+backticks+`cate` ran coreutils truncate
# while the scanners read two halves that spell no name.
EXPANSION = re.compile(r"\$\{[^{}]*\}|\$\([^()]*\)"
                       r"|" + chr(96) + r"[^" + chr(96) + r"]*" + chr(96) +
                       r"|\$[A-Za-z_][A-Za-z0-9_]*"
                       r"|\$[@*#?$!0-9-]")



def _ends_in_redirect(seg):
    """True iff seg ends on an UNESCAPED redirection operator.

    `echo \\> & psql ...` ends in a `>` that is a literal argument, not an
    operator, so treating it as one made the next segment open with a phantom
    redirection operand and swallowed the real command word.
    """
    seg = seg.rstrip()
    if seg[-1:] not in ("<", ">"):
        return False
    head = seg[:-1]
    return (len(head) - len(head.rstrip(chr(92)))) % 2 == 0


def _brace_forms(word):
    """Every literal a simple `{a,b}` brace expansion can produce.

    Bash expands braces LONG after this scan, so `trun{ca,ca}te` is one token
    here and its text is not a command name. Bounded on purpose: at most
    BRACE_CAP results, and anything nested or larger is left to the unreadable
    rule below rather than expanded.
    """
    forms = [word]
    # Bash expands NESTED groups too (`tr{un,{xx,yy}}cate`), so re-run until no
    # group is left. Bounded twice - by BRACE_CAP and by the depth - because an
    # unbounded expansion is a denial of service on a 3s hook budget.
    for _ in range(BRACE_DEPTH):
        if not any(BRACE_SPLIT.search(f) for f in forms):
            return forms
        grown = []
        for form in forms:
            step = [""]
            for i, part in enumerate(BRACE_SPLIT.split(form)):
                alts = _brace_alts(part) if i % 2 else [part]
                if not alts or len(step) * len(alts) > BRACE_CAP:
                    return [BRACE_OVERFLOW]
                step = [f + a for f in step for a in alts]
            grown.extend(step)
            if len(grown) > BRACE_CAP:
                return [BRACE_OVERFLOW]
        forms = grown
    # Out of depth with braces still standing. The forms in hand are HALF
    # expanded, so they spell a name only by accident - refuse them.
    if any(BRACE_SPLIT.search(f) for f in forms):
        return [BRACE_OVERFLOW]
    return forms


def _brace_alts(part):
    """The literals one brace group yields: `a,b` alternation or `a..b` range.

    ACCEPTED LIMIT on exhaustion: a group too large or nested deeper than the
    caps is refused rather than expanded, and the caller then reads the word as
    it stands. Failing CLOSED there means warning on any oversized brace group,
    which is the measured-and-declined rule recorded in has_truncate. Writing
    `tr{{{{{un,xx},yy},zz},aa},bb}cate` takes one command string that carries
    the whole indirection - the same class as the other limits here, and the
    caps exist because an unbounded expansion is a denial of service on a 3s
    hook budget.

    ACCEPTED LIMIT: extglob patterns (`@(truncat?|nope)`) are not expanded.
    They require `shopt -s extglob` to be enabled in the same command, and
    adding a second expander for them is the enumerate-the-spellings ladder
    this file has declined three times already.

    ACCEPTED OVER-WARN: shlex has already dropped quote provenance by the time
    this runs, so `"trun{ca,ca}te"` - which bash leaves LITERAL - expands here
    all the same and warns. Quote provenance is the one thing this scanner
    fundamentally cannot recover (it is why the whole file reads command
    POSITION rather than text), over-warning is its documented safe direction,
    and the replay measured the cost at zero.
    """
    if "," in part:
        return part.split(",")
    lo, _, hi = part.partition("..")
    hi = hi.split("..")[0]                      # ignore any step
    if len(lo) == 1 and len(hi) == 1:
        a, b = ord(lo), ord(hi)
        step = 1 if b >= a else -1
        if abs(b - a) + 1 > BRACE_CAP:
            return []
        return [chr(c) for c in range(a, b + step, step)]
    try:
        a, b = int(lo), int(hi)
    except ValueError:
        return []
    step = 1 if b >= a else -1
    if abs(b - a) + 1 > BRACE_CAP:
        return []
    return [str(n) for n in range(a, b + step, step)]


def _has_payload(tok):
    """True iff tok may CARRY a command rather than be one.

    Literal whitespace is the obvious case (`sh -c "truncate -s 0 f"`), but an
    expansion supplies the separators just as well once the payload runs:
    `watch ${IFS}psql...` has no literal space at all. So does an operator -
    `watch \x27true;psql<<<q\x27` is a two-command payload written without one
    space. Any shell metacharacter therefore means "parse this", and the
    recursion still terminates: a payload of a SINGLE token has no later tokens
    for the wrapper branch to recurse on.

    ACCEPTED LIMIT, MEASURED and declined: a NON-SHELL interpreter that execs
    another program from inside its own runtime - a python3 -c whose script
    calls execvp, or the perl/ruby/node/awk equivalents - is not read as a
    payload carrier. That payload is a PROGRAM in another language, and deciding
    what it runs needs that language rather than a shell tokeniser. The
    fail-closed alternative is to refuse every interpreter -c / -e payload
    unread; on the 35,918-command corpus that is 2,139 commands (6.0%), which
    would more than TRIPLE this guard total of 624 prompts. Enumerating
    interpreters and their exec spellings is the ladder this file declines
    everywhere else, in a language where the spellings are unbounded. The SHELL
    interpreters are covered, because a shell payload is what this can read.
    """
    return any(ch in tok for ch in
               (" ", "\t", "\n", "$", chr(96), ";", "&", "|", "<", ">", "(", ")"))


FIND_NAMED = ("-name", "-iname", "-path", "-ipath", "-wholename",
              "-lname", "-ilname")
# Selectors that pick a file by something OTHER than a literal pattern. A
# regex would need a regex engine to decide, and -samefile names an inode.
# The boolean operators are here for a different reason: `-name X -o -type f`
# is a TREE, and reading a -name out of it as though it constrained the whole
# expression is wrong - the other branch selects freely. That is the whole
# documented operator table, `,` included: the comma joins two INDEPENDENT
# expressions, so `-name "*.log" , -type f -exec {} ;` runs the placeholder over
# everything the right side matched while a -name sat readable on the left.
FIND_OPAQUE = frozenset(("-regex", "-iregex", "-samefile", "-inum",
                         "-o", "-or", "-not", "!", "(", ")", ","))


def _pattern_rest(tok):
    """The case BODY carried in the pattern token, or None if none closes here.

    The delimiter is the first `)` that is NOT inside a substitution. Neither
    fixed choice works: splitting at the FIRST paren breaks `x$(true))`, whose
    pattern carries its own pair, and splitting at the LAST one breaks
    `x)psql$(true)`, whose BODY does - and that one discarded the body whole.
    Counting the nesting is the only reading that answers both.
    """
    # bash allows an optional OPENING paren on a case pattern, and `(x)` is
    # balanced - counting it as a group hid the body behind it.
    body = tok[1:] if tok.startswith("(") else tok
    depth = 0
    i = 0
    while i < len(body):
        ch = body[i]
        if ch == "$" and body[i + 1:i + 2] == "(":
            depth += 1
            i += 2
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            if depth == 0:
                return body[i + 1:]
            depth -= 1
        i += 1
    # Balanced, yet a paren is here. shlex has already dropped the quoting that
    # would say whether the opener was a REAL substitution, so a QUOTED opener
    # arrives balanced although its `)` is the delimiter. Close at the last one:
    # reopening command position over-warns, while leaving the state stuck in
    # "pattern" swallows the whole body and warns on nothing.
    if ")" in body:
        return body.rsplit(")", 1)[1]
    return None


def _exec_placeholder(toks, j):
    """True iff `{}` holds the COMMAND slot of the -exec argv starting at j.

    `-exec {} -s 0 f` RUNS the file that was found; `-exec chmod 644 {} ;`
    merely passes it as an argument. A wrapper and its assignments may sit in
    between (`-exec env FOO=1 {} ...`), so walk the slot the way the main walk
    does. Peeking at a fixed offset missed every one of those.

    Past a WRAPPER the walk stops reading and starts refusing. A wrapper option
    takes an OPERAND - `sudo -u root {}` - and that operand is a bare word the
    scan above cannot tell from a command word, so `-u root` used to end the
    walk one token before the placeholder it was looking for. Learning the
    option arity of every wrapper is the enumerate-the-spellings ladder;
    refusing the unreadable is the inversion this file uses elsewhere. So once a
    wrapper has been seen, any `{}` still standing before `;` or `+` is treated
    as holding the slot, whatever sits in between.
    """
    wrapped = False
    for t in toks[j + 1:]:
        if t in (";", "+"):
            return False             # argv ended without the placeholder
        # CONTAINS the placeholder, not equals it. find substitutes `{}` anywhere
        # in an argument, so `-execdir ./{} -s 0 f` runs the file it found just
        # as `-exec {} ...` does, and an exact match read it as an operand.
        if "{}" in t:
            return True
        # _matches_tok, not _reads_as: `/usr/bin/e?v` resolves to env, and
        # an exact reading did not know a wrapper held the slot.
        if _matches_tok(t, WRAPPERS):
            wrapped = True
            continue
        if wrapped or t.startswith("-") \
                or ("=" in t and not t.startswith("-")):
            continue                 # still in front of the command word
        return False                 # something else took the slot
    return False


def _find_selects(toks, names, action=None):
    """Can `find ... -exec {}` end up running one of `names`?

    The placeholder runs the file that was FOUND, so the SELECTION predicates
    are what name the command. Read the ones carrying a literal pattern; when
    NOTHING readable constrains the match - no name predicate at all
    (`find /usr/bin -type f -exec {} ;`), or an opaque one alongside it - the
    selected file is unconstrained, and an unconstrained file may be any of
    them. Refusing the unreadable is the same inversion the rest of this file
    uses; enumerating predicate spellings is the ladder that has no top.

    Only what precedes THIS action, and only what is a predicate. find
    evaluates left to right and stops at the first false term, so a `-name`
    written after the action had not been tested when the placeholder ran. And
    everything from an EARLIER action token to its `;` or `+` is that action
    ARGV, where a `-name` is an argument to the command being run rather than a
    constraint on the search: `-exec echo -name ;` narrows nothing. Truncating
    at the FIRST action instead read only the first branch of
    `-name never -exec echo {} ; -o -name truncate -exec {} ...`, which is the
    branch that does not run.
    """
    readable = False
    limit = len(toks) if action is None else action
    i = 0
    while i < limit:
        t = toks[i]
        if _reads_as(t, DISPATCH):
            i += 1
            while i < limit and toks[i] not in (";", "+"):
                i += 1
            i += 1
            continue
        if t in FIND_NAMED and i + 1 < len(toks):
            pattern = toks[i + 1]
            # A COMPUTED pattern reads as nothing and therefore constrains
            # nothing: `-name "$C"` selects whatever C holds. Counting it as
            # readable let a predicate that says nothing stand in for one that
            # says the selection is safe - the same unreadable-command-word
            # inversion the walks above already make, one argument along.
            if "$" not in pattern and chr(96) not in pattern:
                readable = True
                # find drops a backslash before an ordinary character, so
                # `-name SQtruncat\eSQ` selects truncate. Reading the escaped
                # spelling literally concluded the predicate could not select
                # it, and a readable predicate that cannot match is what says
                # the selection is SAFE.
                if _matches_tok(pattern, names) \
                        or _matches_tok(pattern.replace(chr(92), ""), names):
                    return True
            i += 2
            continue
        i += 1
    # Normalised: a computed operator (`-${EMPTY}o`) expands to a real one,
    # and comparing raw tokens let it slip past as an unknown word - so the
    # safe branch appeared to constrain a selection it never touched.
    # ...over the same prefix. An operator written AFTER an action cannot
    # retroactively unconstrain it, and scanning the whole argv made a settled
    # `-name echo -exec {} ;` look unconstrained because a `,` followed it.
    return not readable or any(t in FIND_OPAQUE
                               or _strip_expansions(t) in FIND_OPAQUE
                               for t in toks[:limit])


def _matches(word, names):
    """True iff word IS one of names, or is a GLOB that can expand to one.

    Bash performs pathname expansion after this scan, so `/usr/bin/truncat?`
    and `psq?` are command words that reach the real executable while spelling
    a name that is in no set. fnmatch answers exactly, with no text bound and
    therefore no false positive: a pattern that cannot produce the name does
    not match.
    """
    if word in names:
        return True
    if BRACE_OVERFLOW in word:
        return True                  # an unexpandable group may yield any name
    # An EXTGLOB operator makes the pattern unreadable to fnmatch, which has no
    # such syntax: `@(truncat?|nope)` reaches the real binary while fnmatch
    # answers no. The operator set is the documented five, not a growing list,
    # and refusing the unreadable is the inversion used throughout this file.
    # ...but not in an ASSIGNMENT, whose value is data. A regex written into a
    # variable carries `+(` and `*(` constantly (`RE="^[A-Za-z0-9_]+("`), and
    # those are quantifiers, not pathname operators. Measured: this guard is
    # what keeps the rule at a handful of prompts instead of dozens.
    if not ASSIGN_PREFIX.match(word) \
            and any(op in word for op in ("?(", "*(", "+(", "@(", "!(")):
        return True
    if not any(ch in word for ch in "*?["):
        return False
    # fnmatch implements a SUBSET of the bash bracket grammar. Every bracket
    # expression matches exactly one character, so `?` is the faithful stand-in
    # for all of them - see the note on GLOB_BRACKET for why the whole
    # construct is replaced rather than the forms fnmatch happens to miss.
    pattern = GLOB_BRACKET.sub("?", word)
    # A `]` LEFT OVER after that substitution can only be there because shlex
    # erased the backslash that made it part of the bracket: bash reads
    # `truncat[e\]]` as one character from {e, ]}, while the token this scan
    # receives is `truncat[e]]`, whose stray `]` spells a name one character
    # too long. Dropping it is the same fail-closed reading the whole-bracket
    # rule already takes - what it costs is a literal `]` in a command name.
    pattern = pattern.replace("]", "")
    # ACCEPTED OVER-WARN, pinned: a bare `*` matches every name in every set,
    # so a glob operand at command position - `echo hi | docs/*`, or a case
    # pattern whose chunk lost its `case` header to a newline - warns. A
    # density rule that required the pattern to SPELL most of the name removed
    # those two prompts and opened a fail-open in exchange:
    # `[t][r][u][n][c][a][t][e]` spells the whole word in character classes and
    # measures as zero literal characters. Counting brackets more cleverly is
    # the enumerate-the-spellings ladder this file has declined four times, and
    # the measured cost of the fail-CLOSED answer is 19 prompts in 26,454 -
    # nearly all of them a multi-line `case` whose pattern alternatives the
    # chunk splitter cuts at the `|`, leaving a bare `*` holding a slot.
    return any(fnmatch.fnmatchcase(n, pattern) for n in names)


def _after_unmatched_close(tok):
    """The token past an unmatched `)`, or the token itself when it balances."""
    depth = 0
    cut = -1
    for i, ch in enumerate(tok):
        if ch == "(":
            depth += 1
        elif ch == ")":
            if depth == 0:
                cut = i
            else:
                depth -= 1
    return tok[cut + 1:] if cut >= 0 and cut + 1 < len(tok) else tok


def _cmd_word(tok):
    """A token normalised to the command NAME it would run.

    Strips attached grouping (`(psql`), the directory part of a path, and an
    ATTACHED redirection or expansion - bash tokenises on `<`, `>` and a word
    split, shlex does not, so `psql>out`, `truncate<<<q` and
    `truncate${IFS}-s${IFS}0` all arrive as one token whose text is not a name.
    """
    # Order matters. Cut the redirection first (`truncate>/tmp/x` would
    # otherwise basename to `x`), take the basename next (`$PWD/truncate` is a
    # literal name behind an expansion), and only then cut at the expansion
    # (`psql${IFS}-c`). Cutting at `$` first threw the basename away.
    # Past an UNMATCHED `)` first. split_segments cuts a case at its `|`, so a
    # later alternative arrives as its own segment with the pattern still glued
    # to the body - `case y in x|y)truncate ...` hands the walk `y)truncate`,
    # which is a word in no set at all while the command it runs is truncate.
    # An unmatched close is the only shape that carries this: a substitution or
    # a group balances, so `$(printf x)y` is untouched.
    tok = _after_unmatched_close(tok)
    # The FIRST NON-EMPTY field, not the first field. An expansion that SPLITS
    # can also LEAD - `${IFS}truncate${IFS}-s` runs truncate - and taking field
    # zero there yields the empty string, which is in no set and matches
    # nothing. An empty command word names nothing in any case, so reading past
    # it costs no precision: the fields after it are exactly the words bash
    # would have gone on to read.
    # Split on the expansions FIRST, take the basename of the chosen field
    # SECOND. Basenaming the whole token instead read the last path component of
    # the last FIELD: `${IFS}rm${IFS}-rf${IFS}/etc` basenamed to `etc`, a word in
    # no set at all, while bash field-splits it into `rm -rf /etc`.
    raw = REDIR_CUT.split(tok.lstrip("({"), 1)[0]
    for field in _expansion_fields(raw):
        field = EXPAND_CUT.split(field, 1)[0]
        if field:
            return field.rsplit("/", 1)[-1].lower()
    return ""


def _reads_as(tok, names):
    """True iff tok reads as one of `names` in either _cmd_word reading.

    The destructive NAMES have had the empty-expansion rejoin since _matches_tok;
    the structural vocabulary - wrappers, dispatchers, control words - was still
    compared against the first reading alone. That asymmetry is itself a bypass:
    `e${EMPTY}nv truncate ...` runs env, but the walk did not see a wrapper and
    so never looked past it for the command word it hides.

    Narrow like _spells, and for the same reason: a glob must not match a
    structural keyword, or a bare `*` would turn every operand into a wrapper.
    """
    return _cmd_word(tok) in names or _cmd_word(_strip_expansions(tok)) in names


def _spells(tok, name):
    """True iff tok spells exactly `name` in either reading _cmd_word takes.

    The narrow sibling of _matches_tok, and narrow ON PURPOSE. Its caller walks
    EVERY token of a segment rather than only command position, so admitting
    globs there would let a bare `*` operand match any name at all. What this
    adds is only the empty-expansion rejoin: `r${EMPTY}m`, `r$@m` and the
    backtick spelling are all the word rm, and the inline basename comparison
    that preceded it read none of them.
    """
    if _cmd_word(tok) == name or _cmd_word(_strip_expansions(tok)) == name:
        return True
    # The greedy reading too - see _matches_tok. A QUOTED close inside an
    # expansion is gone by the time this runs, so the depth walk shuts at the
    # first delimiter and orphans the rest of the name.
    for opener, closer in (("$(", ")"), ("${", "}")):
        at = tok.find(opener)
        shut = tok.rfind(closer)
        if at >= 0 and shut > at \
                and _cmd_word(tok[:at] + tok[shut + 1:]) == name:
            return True
    return False


def _matches_tok(tok, names):
    """_matches over every command NAME a raw token can spell.

    An expansion is two things at once and _cmd_word only reads one of them.
    Cutting at the `$` is right when the expansion SEPARATES - `psql${IFS}-c`
    runs psql - and blind when it expands to NOTHING and the literal fragments
    rejoin: `${EMPTY}truncate` cut to the empty string and matched no name at
    all, so the command ran unannounced.

    Removing the expansions instead is the same reading the SQL scanner already
    applies to its keyword, and it is bounded in the same way: the removed form
    only ever matches when the LITERAL fragments themselves spell the name, so
    `psql${IFS}-c` yields `psql-c` and matches nothing new. That makes this a
    second reading of one token, not the fail-CLOSED "unreadable command word"
    rule measured and declined below at 23 extra prompts.
    """
    if _matches(_cmd_word(tok), names):
        return True
    rejoined = _cmd_word(_strip_expansions(tok))
    if rejoined and _matches(rejoined, names):
        return True
    # A third reading, for a close that was QUOTED. Bash treats the `)` in
    # `$(x=SQ)SQ)` - and the `}` in `${x+SQ}SQ}` - as literal text inside the
    # expansion; shlex drops the quotes before this scan sees them, so the depth
    # walk closes at the FIRST delimiter and leaves the rest of the name
    # orphaned. Removing everything from the first opener to the LAST close is
    # the opposite reading, and it only matches when the fragments either side
    # spell the name themselves.
    for opener, closer in (("$(", ")"), ("${", "}")):
        at = tok.find(opener)
        shut = tok.rfind(closer)
        if at >= 0 and shut > at:
            greedy = _cmd_word(tok[:at] + tok[shut + 1:])
            if greedy and _matches(greedy, names):
                return True
    return False

# A command word REBOUND by name rather than by value - `alias db=psql`,
# `hash -p /usr/bin/psql db`, an eval-built definition. The binding is static
# text, so no expansion marks the call site as unreadable. Matched at COMMAND
# position, never as text: `echo alias psql truncate` rebinds nothing.
REBINDERS = {"alias", "hash", "eval"}

# The only commands whose options dispatch a FURTHER command word.
DISPATCHERS = {"find"}

# Options whose VALUE is an executable rather than data. The generic rule
# for `NAME=value` requires a payload, so `docker run --entrypoint=truncate`
# read as an ordinary assignment and the command it names went unseen. This
# is the documented option of the container launchers already listed in
# WRAPPERS, not an open-ended table.
EXEC_VALUE_OPTS = ("--entrypoint",)

# `NAME=`, `NAME[i]=`, `NAME+=` - a prefix assignment, not a command word.
ASSIGN_PREFIX = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]*\])?\+?=")


def _assign_prefix(tok, word):
    """True iff the token is a `NAME=value` prefix rather than a command word.

    Read from the RAW token. _cmd_word takes a BASENAME, and a value holding a
    path loses the assignment with it: `X=/tmp` normalised to `tmp`, which
    carries no `=` at all, so the prefix took command position and the real
    command word behind it was read as an operand. `PATH=/usr/bin psql` walked
    through on exactly that.

    The normalised form is still consulted, because it is the one that survives
    an attached redirection or expansion.
    """
    return bool(ASSIGN_PREFIX.match(tok.lstrip("({"))) \
        or ("=" in word and not word.startswith("-"))

def recursive_targets(argv):
    """(is_recursive, targets) for an rm argv starting at the command word.

    Each entry after the command word is a (structural, raw) pair:
    `structural` is expansion-stripped and decides whether the position is an
    option or an operand, so a flag hidden behind a vanishing substitution
    (`$(true)-rf`) still registers; `raw` is the UNSTRIPPED text and is what
    an operand position contributes to `targets`, so a genuine `$VAR` prefix
    survives into is_safe(). Collapsing an operand to its stripped
    form here erased that `$` and let `${P}out` clear as the always-relative-
    safe `out`, even though bash expands it to `${P}out`, e.g. `/important/out`.
    """
    recursive = False
    targets = []
    opts = True
    for structural, raw in argv[1:]:
        tok = structural
        if opts and tok == "--":
            opts = False
        elif opts and len(tok) >= 3 and tok.startswith("--") \
                and "recursive".startswith(tok[2:]):
            # GNU rm accepts any unambiguous prefix of --recursive (--r, --rec,
            # and so on). recursive is the only r-prefixed long option rm has,
            # so any --r prefix means recursive. Verified.
            recursive = True
        elif opts and tok.startswith("--"):
            pass
        elif opts and len(tok) > 1 and tok.startswith("-"):
            if "r" in tok[1:].lower():
                recursive = True
        else:
            targets.append(raw)
    return recursive, targets


# KNOWN LIMIT, same shape as the SQL client list below: an allowlist of launcher
# binaries is never complete, so an unlisted one puts itself in the command slot
# and the truncate behind it reads as an operand. Add names here as they come up.
# The alternative — treating every unrecognized command word as a wrapper — is
# the any-token scan, which is what cost 11% of ALL prompts in false positives.
# `builtin` STAYS, and the review finding that asked for its removal is
# declined by the tests in this repo: it runs shell builtins, but two of
# those reach an external binary - `builtin command psql ...` and
# `builtin exec psql ...` both run the real client. Dropping it opened
# exactly the two spellings pinned in the truncate-context suite. What it
# costs is the documented wrapper-tail over-warn (`builtin echo truncate`),
# the same trade every other wrapper here already makes.
WRAPPERS = {"builtin",
            "sudo", "doas", "su", "runuser", "env", "xargs", "nohup", "timeout",
            "command", "time", "stdbuf", "nice", "ionice", "exec",
            "setsid",
            "chroot", "unshare", "flock", "script", "watch", "parallel",
            "caffeinate", "arch", "xcrun",
            # Remote and container dispatchers: the command they run is an
            # operand, so without these the dispatcher name consumes the slot
            # and `ssh dbhost psql -c ...` reads as if psql were an argument.
            "ssh", "docker", "podman", "kubectl", "nerdctl", "lima", "distrobox",
            "toolbox", "vagrant", "adb",
            # `coproc` takes an OPTIONAL name before the command
            # (`coproc worker psql ...`), so the slot after it is not reliably
            # the command word. Scanning every later token is the safe read.
            "coproc",
            # An interpreter run by NAME carries its script in an operand
            # (`sh -c "psql -c ..."`). At the top level the chunk splitter
            # already lifts that payload out, but a nested one does not reach
            # it - `find . -exec sh -c "..."` consumed the slot with `sh` and
            # read the payload as an ordinary argument.
            "sh", "bash", "zsh", "dash", "ksh", "ash", "busybox",
            # `trap HANDLER SIGNAL` is the same shape wearing a builtin name:
            # the handler is a command string that runs later, and treating it
            # as data let `trap "psql -c ..." EXIT` through.
            "trap"}


# `if`/`while`/`until` introduce a CONDITION, which is an executed command:
# `if truncate -s 0 audit.log; then :; fi` runs truncate. They belong here with
# `then`/`do`, not treated as command words in their own right.
CONTROL = {"if", "while", "until", "then", "do", "else", "elif", "!", "{", "(",
           "&&", "||", ";", "|", "&", "eval"}
# `case` is NOT a plain control token: its SUBJECT and its PATTERNS are data,
# not commands. Treating the three words as unconditional control made
# `echo in truncate` and `case truncate in x) echo no;; esac` prompt. The
# construct is walked as a small state machine instead - see has_truncate.
CASE_WORDS = {"case", "in", "esac"}
# find/xargs style dispatch: the token AFTER these is a command word.
DISPATCH = {"-exec", "-execdir", "-ok", "-okdir", "--exec"}


DYN_FD = re.compile(r"^\{[A-Za-z_][A-Za-z0-9_]*\}[<>]")
DYN_FD_NAME = re.compile(r"^\{[A-Za-z_][A-Za-z0-9_]*\}")
# A redirection operator carrying no target takes the NEXT token as its target.
# Operators that take their operand as the NEXT token when written separated.
# `>&`, `<&` and `<<-` belong here for the same reason the rest do: bash allows
# `>& out.log cmd`, and omitting them let the operand consume the command slot,
# so the real command word read as an argument and went unseen.
BARE_REDIRECT = ("<", ">", ">>", "<<", "<<<", "&>", ">|", "<>", "&>>",
                 ">&", "<&", "<<-")


def _is_redirect(tok):
    """A leading redirection is not the command word: `</dev/null truncate ...`.

    Covers the numeric form (`2>f`) and bash dynamic-FD allocation (`{fd}>f`),
    which likewise runs the command that follows it.
    """
    return (tok.lstrip("0123456789")[:1] in ("<", ">")
            or tok.startswith("&>") or bool(DYN_FD.match(tok)))


def _expansion_fields(text):
    """The literal fragments an expansion SEPARATES, nested ones included.

    _strip_expansions answers "what if every expansion were empty"; this answers
    "where would the fields fall if one of them were whitespace". Same walk, one
    marker instead of nothing, because the one-level EXPANSION regex splits
    neither `${x:-${IFS}}` nor `$($(printf " "))` - and a nested default is a
    perfectly ordinary way to spell a separator.
    """
    return _strip_expansions(text, mark="\x01").split("\x01")


def _strip_expansions(text, mark=""):
    """Every expansion removed, NESTED ones included, in ONE left-to-right pass.

    EXPANSION matches one level: its bodies are `[^{}]*` and `[^()]*`, so
    `${x:-${y}}` and `$($(true))` match nothing at all and the literal fragments
    either side never met. Re-applying the one-level rule to a fixpoint reaches
    the right answer but rescans the whole string per level, which is quadratic:
    an 8,000-deep nest spent the scanner 3s alarm before it could answer.

    So walk the text once instead, matching each opener to its own closer by
    DEPTH. Linear in the input, no pass count to blow past, and no regex asked
    to balance its own delimiters. An opener that never closes takes the rest of
    the text with it - it is unreadable either way, and _torn_substitution is
    what reports that separately.
    """
    out = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == chr(96):                    # `...` - no nesting, ends at the pair
            close = text.find(chr(96), i + 1)
            out.append(mark)
            i = n if close < 0 else close + 1
            continue
        if ch != "$":
            out.append(ch)
            i += 1
            continue
        nxt = text[i + 1:i + 2]
        if nxt in ("(", "{"):
            shut = ")" if nxt == "(" else "}"
            depth = 0
            j = i + 1
            while j < n:
                if text[j] == nxt:
                    depth += 1
                elif text[j] == shut:
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            out.append(mark)
            if j >= n:
                i = n
                continue
            j += 1
            # ...and the RUN of closers behind it. A quoted close inside the
            # body is a literal character bash keeps, but shlex has already
            # dropped the quotes, so `$(x=SQ)SQ)` arrives as `$(x=))` and the
            # depth walk stops one character early. Eating the run rejoins the
            # fragments for as many composed expansions as the word carries,
            # where a single first-to-last reading only ever handled one.
            while j < n and text[j] == shut:
                j += 1
            i = j
            continue
        j = i + 1
        if j < n and (text[j].isalpha() or text[j] == "_"):
            while j < n and (text[j].isalnum() or text[j] == "_"):
                j += 1
            out.append(mark)
            i = j
            continue
        if j < n and text[j] in "@*#?$!-0123456789":
            out.append(mark)
            i = j + 1
            continue
        out.append(ch)                       # a lone `$` is literal
        i += 1
    return "".join(out)


def _torn_substitution(tok):
    """True iff tok carries a substitution OPENER that does not close in it.

    A substitution can hold whitespace and nesting - `$(printf "")`,
    `$(if true; then :; fi)` - and shlex splits the word at that whitespace, so
    the halves of the real command name land in DIFFERENT tokens and no amount
    of removing expansions from one of them puts the name back together.

    Teaching EXPANSION to match nested, whitespace-bearing substitutions is the
    enumerate-the-grammar ladder; this is the inversion. A token whose opener
    does not close inside it is a command word this scan CANNOT read, and an
    unreadable command word at command position is the case every walk here
    already refuses. Narrow on purpose: it says nothing about the ordinary
    `echo $(date)` operand, whose substitution closes in its own token.

    LITERAL TEXT BEFORE THE OPENER is required, and that requirement is what
    makes the rule affordable. A token that BEGINS with the opener is a whole
    substitution standing in for a word - `bash script.sh "$(git rev-parse ...)"`
    - which is unreadable for the older reason already measured and declined,
    not torn in half by one. Firing on it too was measured at 240 extra prompts
    over 26,454 replayed commands, nearly all of them that exact shape; with the
    prefix required the same measurement is zero. A name split across a
    substitution always has its first half in front of the opener.
    """
    at = tok.find("$(")
    if at > 0:
        # DEPTH, not the first `)`: a nested substitution closes itself first,
        # so `trun$(true$(true)` looked closed while the word it opens runs on
        # into the next token.
        depth = 0
        i = at
        while i < len(tok):
            if tok[i] == "(":
                depth += 1
            elif tok[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        if depth > 0:
            return True
        # ...and a close that LANDS but leaves no literal suffix. Bash reads
        # `trun$(x=SQ)SQ; :)cate` as one word, because the `)` inside the quotes
        # is data; shlex drops the quotes and the depth walk stops at it, ending
        # the token on `trun$(x=);`. A real command word does not end on its
        # substitution with punctuation trailing - the word continues in the
        # next token, which carries the unmatched close and the rest of the
        # name. A token whose suffix is ordinary text (`e`+backticks+`cho`) is
        # untouched, which is what keeps this off benign spellings.
        suffix = tok[i + 1:] if i < len(tok) else ""
        if not suffix or not suffix[0].isalnum():
            return True
    at = tok.find(chr(96))
    # A backtick has no distinct closer, so PAIRING is all there is to read.
    return at > 0 and tok.count(chr(96)) % 2 == 1


def _expansion_only(tok):
    """True iff removing every expansion leaves nothing of the token."""
    return bool(tok) and not _strip_expansions(tok).strip("(){}")


def _whole_substitution(tok):
    """True iff tok is ENTIRELY one `$(...)` - not merely starting with one.

    Balance alone is not enough: `$(echo x)()` is balanced and starts with `$(`
    yet its final `)` is a case delimiter. Track depth and require it to reach
    zero exactly at the last character.
    """
    # Exactly one `(` (the leading one) and exactly one `)` (the last char).
    # Depth-tracking is not enough: shlex has already dropped quote provenance,
    # so a LITERAL paren inside the substitution counts the same as a syntactic
    # one and can balance a case delimiter. Anything more complex is treated as
    # a closer, which over-warns - the safe direction.
    # A non-empty body is required: quoted TEXT spelling a bare opener collapses to the
    # empty `$()` once shlex drops the quotes, and treating that as a real
    # substitution would hand a case pattern the command position.
    #
    # KNOWN LIMIT, same family as the ANSI-C quoting one below: shlex removes
    # quote provenance entirely, so quoted text spelling a NON-empty
    # substitution is indistinguishable from the real thing. The
    # alternative - treating every such token as a closer - over-warns on the
    # ordinary `echo "$(cmd)" ...` operand this change exists to keep silent.
    return (tok.startswith("$(") and tok.endswith(")") and len(tok) > 3
            and tok.count("(") == 1 and tok.count(")") == 1)


SQL_CLIENTS = {"psql", "pgcli", "mysql", "mysqlsh", "mycli", "mariadb",
               "sqlite3", "litecli", "sqlcmd", "sqlplus", "snowsql", "usql",
               "clickhouse-client", "clickhouse", "duckdb", "cockroach",
               "cqlsh", "beeline", "trino", "presto", "impala-shell",
               "spark-sql", "bq"}
# Text form, used ONLY to bound the unreadable-command-word rule in
# has_sql_client. Matched against a haystack with quotes and backslashes
# REMOVED, so `p"s"ql` and `p\sql` are the same needle as `psql`.
SQL_NAME_RE = re.compile(r"\b(%s)\b" % "|".join(
    re.escape(n) for n in sorted(SQL_CLIENTS, key=len, reverse=True)))
QUOTING = re.compile(r"[\"\x27\\]")


def _command_word_in(chunks, names, unreadable=True):
    """True iff any name runs as a COMMAND WORD.

    Mirrors the has_truncate walk deliberately - a simplified copy missed
    separated redirection operands, wrapper option arguments, and case bodies,
    so `<<< q psql`, `sudo -u postgres psql` and a psql inside a case arm all
    went unseen.
    """
    for chunk in chunks:
        prev_seg = None
        for _op, seg in split_segments(chunk):
            try:
                toks = shlex.split(_fold_ansi_c(seg), posix=True)
            except ValueError:
                toks = seg.split()
            # split_segments cuts at `&`, which SPLITS the separated `>& file`
            # and `2>& 1` redirection forms: the operand then lands at the head
            # of the next segment and consumes the command slot, so the real
            # command word reads as an argument. If the previous segment ended
            # on a redirection operator, this segment opens with its operand.
            # ANY operator, not just `&`. What carries the operand is the
            # DANGLING redirection at the end of the previous segment, never the
            # character that happened to split there: `>| file cmd` splits on the
            # `|` of the clobber operator, leaving the same orphaned target.
            carry_operand = (prev_seg is not None
                             and _ends_in_redirect(prev_seg))
            prev_seg = seg
            cmd_pos = True
            skip_next = carry_operand
            case_state = None
            seg_cmd = None
            # The FIRST command word of the segment, never overwritten. A
            # dispatcher stays the dispatcher for its whole argv, but seg_cmd
            # follows the most RECENT command word - so `-exec` reopened the
            # slot, the command it ran took seg_cmd, and a SECOND `-exec` in
            # the same find no longer saw a find in front of it.
            seg_head = None
            for j, tok in enumerate(toks):
                if skip_next:
                    skip_next = False
                    # ...but a redirection operand never swallows a
                    # DISPATCH flag. shlex has erased the quoting, so a
                    # quoted `>` used as DATA - `find . -name SQ>SQ` -
                    # reads as the operator, and letting its operand eat
                    # the `-exec` behind it hid the command find then
                    # ran. A redirection target genuinely spelled -exec
                    # is not a shape worth keeping quiet for.
                    if tok not in DISPATCH:
                        continue
                word_raw = tok.lstrip("({")
                word = _cmd_word(tok)
                # Brace forms come from the RAW token: _cmd_word strips a
                # leading `{`, which is the OPENER of `{psql,psql}`.
                if cmd_pos and (_matches_tok(tok, names)
                                or any(_matches_tok(f, names)
                                       for f in _brace_forms(tok))):
                    return True
                # An UNREADABLE command word hides the name: `C=psql; "$C" -c`,
                # `$(printf psql) -c` and the backtick spelling all run a client
                # this walk cannot resolve. Fail CLOSED on it rather than
                # resolving the value - see the has_sql_client docstring.
                # Normalised the same way the exact match above is: an attached
                # subshell (`("$C" -c ...)`) otherwise reads as unreadable-free.
                # ANYWHERE in the word, not just at its start: `${IFS}` field-
                # splits `psql${IFS}-c${IFS}...` into the client and its
                # arguments, and shlex hands that over as one token whose first
                # characters spell a name that is not in the set. An assignment
                # PREFIX is exempt - `T=$(mktemp -d) cmd` is not a command word.
                if unreadable and cmd_pos \
                        and not ASSIGN_PREFIX.match(word_raw) \
                        and ("$" in word_raw or "`" in word_raw):
                    return True
                if word == "case" and cmd_pos:
                    case_state = "subject"
                    cmd_pos = False
                    continue
                if case_state == "subject":
                    case_state = "in"
                    continue
                if case_state == "in":
                    if word == "in":
                        case_state = "pattern"
                    continue
                if case_state == "pattern":
                    # Bash does not require whitespace after the `)`, so the
                    # body can begin inside this very token: `x)psql -c ...`.
                    # The delimiter is the first paren OUTSIDE a
                    # substitution - see _pattern_rest for why neither the
                    # first nor the last one on its own is right.
                    rest = _pattern_rest(tok)
                    if rest is not None:
                        # ACCEPTED OVER-WARN, raised three times in review
                        # and declined three times: state is NOT carried to the
                        # next `;;`, so a later spaced pattern (`truncate )
                        # echo no`) reads as a command word and warns. A
                        # `;;`-aware state machine was written to answer it and
                        # reverted UNUSED - split_segments has already consumed
                        # the `;;`, so the code could never fire, and a rule
                        # that cannot fire is worse than none. Fixing it
                        # properly means carrying state ACROSS segments, which
                        # loses a truncate in a multi-command case BODY: a
                        # fail-OPEN traded for an over-warn. Pinned in the
                        # truncate-context suite.
                        case_state = None
                        cmd_pos = True
                        if rest:
                            # Hand the body back to the NORMAL walk rather than
                            # judging it here: it can be a prefix, an assignment,
                            # a wrapper with its own arguments, a redirection.
                            # Re-deciding all of that inline is where every
                            # spelling of `x)FOO=bar psql` slipped through.
                            toks.insert(j + 1, rest)
                    continue
                if _is_redirect(tok):
                    skip_next = (DYN_FD_NAME.sub("", tok).lstrip("0123456789")
                                 in BARE_REDIRECT)
                    continue
                # Only AT command position: past it, `then`/`esac` are ordinary
                # operands (`echo truncate then psql`) and reopening the slot on
                # them is the very false-positive class this walk removes.
                # DISPATCH is the exception - `-exec` reopens by definition, and
                # it only ever appears inside find, whose own name has already
                # consumed the slot - so it is scoped to that dispatcher instead.
                # ...or the segment OPENS with the flag. split_segments cuts
                # at `;`, which is exactly how a find action ENDS, so a second
                # action begins a segment of its own with no `find` in front
                # of it. The selection is then unreadable, which _find_selects
                # answers by refusing - the same inversion, one level up.
                if _reads_as(tok, DISPATCH) \
                        and (_matches_tok(seg_head or chr(0), DISPATCHERS) or j == 0):
                    # `-exec {}` runs the file that was FOUND, so the pattern
                    # that selected it is what names the command.
                    if _exec_placeholder(toks, j) \
                            and _find_selects(toks, names, j):
                        return True
                if (cmd_pos and (word == "esac" or word in CONTROL)) \
                        or (_reads_as(tok, DISPATCH)
                            and (_matches_tok(seg_head or chr(0), DISPATCHERS) or j == 0)) \
                        or tok in ("(", ")", "{", "}", ";;"):
                    cmd_pos = True
                    continue
                if _whole_substitution(tok):
                    continue
                # A token made of NOTHING but expansions vanishes when they are
                # empty, so it never held command position at all: with no
                # positional parameters `$@ truncate ...` simply runs truncate.
                # Consuming the slot for it read the real command word as an
                # operand. Preserving the slot is also the safe direction when
                # the expansion is NOT empty - the word is unreadable either way.
                if cmd_pos and not word and _expansion_only(tok):
                    continue
                # A command word TORN across a substitution cannot be read at
                # all - its halves are in different tokens - so refuse it here
                # rather than teach EXPANSION the nested-substitution grammar.
                # An ASSIGNMENT is exempt: `T=$(mktemp -d)` tears in exactly the
                # same place, holds no command slot, and is the safe-artifact
                # binding this guard goes out of its way to stay quiet about.
                # ...and so is an OPTION: a backtick has no distinct closing
                # character, so the TAIL of a torn one (`-d` plus a backtick)
                # looks exactly like its head, and an option was never going to
                # be the command word in the first place.
                if cmd_pos and _torn_substitution(tok) \
                        and not tok.startswith("-") \
                        and not _assign_prefix(tok, word):
                    return True
                if tok.endswith(("{", ";;", ")")):
                    cmd_pos = True       # `f(){ psql ...`, `x) psql ...`
                    continue
                if _assign_prefix(tok, word):
                    continue
                if cmd_pos and _matches_tok(tok, WRAPPERS):
                    # Same reasoning as has_truncate: once a wrapper holds the
                    # slot, its option ARGUMENTS make the real command word
                    # unlocatable, so any later token counts.
                    # A later token can also CARRY a command string rather than
                    # be one: `watch "psql -c ..."` is ONE token after shlex, so
                    # an exact-token match reads the payload as an operand. Same
                    # recursion has_truncate uses; it terminates because a token
                    # without whitespace never re-enters.
                    for k, t in enumerate(toks[j + 1:], j + 1):
                        # A wrapper does not hide a DISPATCHER. `env find ...
                        # -exec {} ...` still runs the file find selected, and
                        # scanning the wrapper tail token by token lost the
                        # dispatcher semantics entirely - the placeholder read
                        # as an ordinary operand.
                        if _reads_as(t, DISPATCH) \
                                and _exec_placeholder(toks, k) \
                                and _find_selects(toks, names, k):
                            return True
                        # An ASSIGNMENT is data even here. _cmd_word takes a
                        # BASENAME, so `env TOOL=/usr/bin/psql echo ok` reads as
                        # the client itself unless the prefix is recognised
                        # first - the same contract the main walk keeps.
                        if ASSIGN_PREFIX.match(t.lstrip("({")):
                            pass
                        elif _matches_tok(t, names) \
                                or any(_matches_tok(f, names)
                                       for f in _brace_forms(t)):
                            return True
                        if _has_payload(t) \
                                and _command_word_in([t], names, unreadable):
                            return True
                        # A wrapper OPTION can carry an executable VALUE:
                        # `ssh -o ProxyCommand=...` runs it through a shell,
                        # while the token reads as an assignment prefix.
                        # A PAYLOAD is required, so an ordinary environment
                        # assignment stays data: `env NOTE=psql echo ok` sets a
                        # variable and runs echo, and reading its value as a
                        # command made every mention of a name a warning.
                        if "=" in t and _has_payload(t) and _command_word_in(
                                [t.split("=", 1)[1]], names, unreadable):
                            return True
                        # ...and an EXEC-VALUED option needs no payload at all:
                        # its value IS the command word by definition.
                        if any(t.startswith(o + "=") for o in EXEC_VALUE_OPTS) \
                                and _matches_tok(t.split("=", 1)[1], names):
                            return True
                    break
                if cmd_pos:
                    seg_cmd = word
                    if seg_head is None:
                        # The RAW token, so the dispatcher test reads it with
                        # the same rejoin the destructive names get: an empty
                        # expansion in `f${EMPTY}ind` left seg_head as `f`, and
                        # the `-exec` behind it was never treated as a dispatch.
                        seg_head = tok
                cmd_pos = False
    return False


def _rebinds(chunks, pattern, names=frozenset()):
    """True iff a rebinder RUNS in a segment whose text matches pattern.

    Both halves are needed. Requiring only the rebinder makes `alias ll=ls`
    beside an unrelated mention of psql warn; requiring only the name is the
    match-anywhere rule this change removes. Scoped to the rebinding segment
    because that is the one place the client name legitimately appears as text.
    """
    for chunk in chunks:
        for _op, seg in split_segments(chunk):
            # unreadable=False: this asks whether a REBINDER runs, and the
            # fail-closed unreadable rule answers True for any `"$C"` command
            # word, which would make every expansion look like a rebind.
            # Normalised the way the command walks normalise, not merely
            # stripped of quotes. Dropping quoting alone leaves an ANSI-C escape
            # and an empty expansion standing, so a `hash -p` whose path spells
            # trunc-ate through a dollar-quote bound a name this search could
            # not read although the command walks could read it perfectly well.
            # Fold FIRST, then lowercase - a decoded escape yields a real
            # character and lowercasing before it leaves that character cased.
            folded = QUOTING.sub("", _fold_ansi_c(seg).lower())
            # BRACE forms too. A binding path can carry a group, and
            # `hash -p /usr/bin/trunc{a..a}te zap` completes to the real name
            # only after the group expands - neither the raw text nor the
            # expansion-stripped text spells it.
            braced = " ".join(f for w in UNESCAPED_SPACE.split(folded)
                              for f in _brace_forms(w))
            # A GLOB in the bound path spells the name only after pathname
            # expansion, and a regex search over the text finds nothing:
            # `hash -p /usr/bin/truncat? zap` binds zap to the real binary.
            # _matches_tok answers that exactly, with no text bound.
            globbed = any(_matches_tok(w, names)
                          for w in UNESCAPED_SPACE.split(folded)) if names \
                else False
            # A rebinder can also bind a LAUNCHER rather than the protected
            # name: `hash -p /usr/bin/env e; e truncate ...` runs truncate
            # through a name this scan has never heard of, and the same trick
            # on find hides an `-exec` dispatch. The new name is unreadable
            # either way, so the launcher binding is what is refused.
            launcher = any(_reads_as(w, WRAPPERS) or _reads_as(w, DISPATCHERS)
                           for w in UNESCAPED_SPACE.split(folded))
            if _command_word_in([seg], REBINDERS, unreadable=False) \
                    and (pattern.search(folded)
                         or pattern.search(_strip_expansions(folded))
                         or pattern.search(braced)
                         or globbed
                         or launcher):
                return True
    return False


def has_sql_client(chunks):
    """True iff a SQL client runs as a COMMAND, not merely appears as a word.

    `grep truncate psql.log` and `echo truncate psql` name a client without
    running one; matching the name anywhere kept exactly the class of false
    prompt this change exists to remove.

    Going semantic must not LOSE detection the raw text used to give, though:
    the pre-change rule matched a client name anywhere, so it warned on
    `C=psql; "$C" -c "TRUNCATE users"`, and reading position alone silently
    cleared it. So an UNREADABLE command word counts too - fail CLOSED on a
    command word this walk cannot resolve rather than resolving its value,
    which is the ladder this file has already declined twice.

    ACCEPTED OVER-WARN, declined deliberately: this answers "does a client RUN
    here", not "does THAT client run the truncate". The bash arm pairs it with
    the word `truncate` appearing anywhere in the command, so
    `psql -c "SELECT 1"; echo truncate` warns. Attributing the word to a
    particular command means modelling which argument of which invocation it is
    - the pipeline case `printf TRUNCATE... | psql` puts them in different
    segments on purpose - and this is a warn-only guard whose documented safe
    direction is over-warning. Not one of the measured false positives had this
    shape; all 20 were the bare english word with no client anywhere.

    That rule is BOUNDED on a client name appearing in the text, and the bound
    is load-bearing in the other direction: unbounded, every `"$GUARD" ...`
    in a command whose text merely mentions truncate warns, which measured at
    17 extra prompts across 356 replayed commands - the english-word false
    positive this change exists to remove, in a narrower dress. The needle is
    matched with quotes and backslashes stripped, so `p"s"ql` is not a spelling
    to chase. A name ASSEMBLED at runtime (`$(printf p%sql s)`) still passes.
    That is the same accepted limit as the variable-command-name and nameref
    ones recorded above: reaching it needs ONE command string carrying the
    setup, the indirection and the payload together - a session attacking its
    own advisory guard, which merely prompts.
    """
    # Fold the ANSI-C dollar the same way the tokenizer does, or this prefilter
    # is the tighter bound: `p$\x27s\x27ql` strips to `p$sql`, which spells no
    # client, and the walk below never runs.
    raw = _fold_ansi_c(" ".join(chunks)).lower()
    text = QUOTING.sub("", raw)
    if not SQL_NAME_RE.search(text):
        # Braces are expanded by bash long after this scan, so `psq{l,l}` does
        # not spell a name yet. Expand each word before giving up - the walk
        # below does the same, and the bound must not be the tighter of the two.
        # Split the RAW text on UNESCAPED whitespace and strip quoting only
        # afterwards: stripping first turns `psq{l,l\ }` into two words and
        # destroys the group before it can expand.
        forms = [QUOTING.sub("", f)
                 for w in UNESCAPED_SPACE.split(raw)
                 for f in _brace_forms(w)]
        if not SQL_NAME_RE.search(" ".join(forms)):
            # A GLOB spells no name either, and fnmatch answers exactly, so
            # this admits `/usr/bin/psq?` without admitting anything a glob
            # cannot actually produce.
            if not any(_matches_tok(f, SQL_CLIENTS) for f in forms):
                return False
    # A name can also be rebound STATICALLY - `alias db=psql`, `hash -p ... db`,
    # an eval-built definition - and then the call site carries no expansion to
    # mark it unreadable. Same fail-CLOSED answer as an unreadable command word,
    # and reached only when a rebinder RUNS with a client already named.
    if _rebinds(chunks, SQL_NAME_RE, SQL_CLIENTS):
        return True
    return _command_word_in(chunks, SQL_CLIENTS)


def has_truncate(chunks):
    """True iff coreutils `truncate` appears as a COMMAND WORD.

    NOTE: this whole block is embedded in a bash single-quoted string, so it
    must contain no apostrophe anywhere, comments included.

    Regex over the raw string cannot do this: it either misses an operand-first
    invocation (`truncate audit.log -s 0`, legal under GNU option permutation)
    or fires on the word inside a quoted literal (a grep -F for the same text).
    Those two demands are contradictory for a text match and were the whole
    reason the bare-word rule mis-fired. shlex settles both — a quoted literal
    collapses into ONE token, so it is never a command word, while wrappers and
    absolute paths (`sudo truncate`, `env truncate`, `/usr/bin/truncate`) still
    expose theirs. Same walk the rm scanner below uses, same reasons.
    """
    # A rebind hides the name here exactly as it does for a SQL client:
    # `hash -p /usr/bin/truncate zap; zap -s 0 f` puts no truncate at command
    # position. Same two-part rule - a rebinder must RUN, in a segment that
    # also names truncate - so `alias ll=ls` beside the word does not warn.
    if _rebinds(chunks, TRUNCATE_WORD, TRUNCATE_SET):
        return True
    for chunk in chunks:
        prev_seg = None
        for _op, seg in split_segments(chunk):
            try:
                toks = shlex.split(_fold_ansi_c(seg), posix=True)
            except ValueError:
                toks = seg.split()
            # split_segments cuts at `&`, which SPLITS the separated `>& file`
            # and `2>& 1` redirection forms: the operand then lands at the head
            # of the next segment and consumes the command slot, so the real
            # command word reads as an argument. If the previous segment ended
            # on a redirection operator, this segment opens with its operand.
            # ANY operator, not just `&`. What carries the operand is the
            # DANGLING redirection at the end of the previous segment, never the
            # character that happened to split there: `>| file cmd` splits on the
            # `|` of the clobber operator, leaving the same orphaned target.
            carry_operand = (prev_seg is not None
                             and _ends_in_redirect(prev_seg))
            prev_seg = seg
            # COMMAND WORD only, not any token: `truncate` is an ordinary
            # operand in `grep -F truncate script.sh` and `echo truncate`, so an
            # any-token scan fires on both. But "first token of the segment" is
            # not the command word either — bash puts assignments, redirections,
            # control keywords, negation and dispatch flags ahead of it. Tracking
            # command POSITION closes that whole class at once, instead of
            # enumerating one more prefix each time another is found.
            cmd_pos = True      # the next non-prefix token runs
            skip_next = carry_operand   # ...unless it is a redirection target
            seg_cmd = None      # the command word this segment actually ran
            seg_head = None     # ...and the FIRST one, which owns the argv
            # None -> not in a case; then subject -> in -> pattern. Only the
            # token AFTER a pattern closes is a command word.
            case_state = None
            for j, tok in enumerate(toks):
                if skip_next:
                    skip_next = False
                    # ...but a redirection operand never swallows a
                    # DISPATCH flag. shlex has erased the quoting, so a
                    # quoted `>` used as DATA - `find . -name SQ>SQ` -
                    # reads as the operator, and letting its operand eat
                    # the `-exec` behind it hid the command find then
                    # ran. A redirection target genuinely spelled -exec
                    # is not a shape worth keeping quiet for.
                    if tok not in DISPATCH:
                        continue
                word = _cmd_word(tok)
                # From the RAW token: _cmd_word strips a leading `{`, which is
                # the OPENER of `{truncate,truncate}`, not grouping punctuation.
                if cmd_pos and (_matches_tok(tok, TRUNCATE_SET)
                                or any(_matches_tok(f, TRUNCATE_SET)
                                       for f in _brace_forms(tok))):
                    return True
                # ACCEPTED LIMIT, measured and declined: an UNREADABLE command
                # word (a VALUED expansion like `$TRUNC`, a brace form too large
                # to expand) cannot be compared at all. `${EMPTY}truncate` is no
                # longer one of these - _matches_tok reads the fragments that
                # rejoin when an expansion is empty, which costs nothing because
                # it only matches when the literals spell the name themselves.
                # Failing CLOSED on the rest - bounded on
                # the text naming truncate, the mirror of what has_sql_client
                # does - was built and MEASURED: 23 extra prompts over 368
                # replayed commands, 6 of the 61 points, because a command that
                # runs `"$GUARD"` and mentions truncate anywhere is the test
                # loop of this very repo. Same call as the two indirection limits already
                # recorded above, for the same reason: it needs one command
                # string carrying setup, indirection and payload together.
                # The SQL side pays no such cost, so it keeps the rule.
                # The case construct: subject and patterns are DATA.
                if word == "case" and cmd_pos:
                    case_state = "subject"
                    cmd_pos = False
                    continue
                if case_state == "subject":
                    case_state = "in"            # the subject is an operand
                    continue
                if case_state == "in":
                    if word == "in":
                        case_state = "pattern"
                    continue
                if case_state == "pattern":
                    # The body may begin in the SAME token as the pattern: bash
                    # does not require whitespace after the `)`.
                    # The delimiter is the first paren OUTSIDE a substitution
                    # - see _pattern_rest for why neither the first nor the
                    # last one on its own is right.
                    rest = _pattern_rest(tok)
                    if rest is not None:         # pattern closed; body follows
                        # ACCEPTED OVER-WARN, raised three times in review
                        # and declined three times: state is NOT carried to the
                        # next `;;`, so a later spaced pattern (`truncate )
                        # echo no`) reads as a command word and warns. A
                        # `;;`-aware state machine was written to answer it and
                        # reverted UNUSED - split_segments has already consumed
                        # the `;;`, so the code could never fire, and a rule
                        # that cannot fire is worse than none. Fixing it
                        # properly means carrying state ACROSS segments, which
                        # loses a truncate in a multi-command case BODY: a
                        # fail-OPEN traded for an over-warn. Pinned in the
                        # truncate-context suite.
                        case_state = None
                        cmd_pos = True
                        if rest:
                            # Re-read by the NORMAL walk: the body may open with
                            # a prefix, an assignment or a wrapper.
                            toks.insert(j + 1, rest)
                    continue                     # patterns are data
                if _is_redirect(tok):
                    # `>x` carries its target; a bare `>` takes the next token.
                    skip_next = (DYN_FD_NAME.sub("", tok).lstrip("0123456789")
                                 in BARE_REDIRECT)
                    continue                     # position is unchanged
                # Only AT command position, and DISPATCH only inside a real
                # dispatcher: past the command word, `then`/`esac`/`-exec` are
                # ordinary operands (`echo truncate then f`) and reopening the
                # slot on them re-creates the bare-word false positive.
                if cmd_pos and (word == "esac" or word in CONTROL):
                    cmd_pos = True               # `then truncate`
                    continue
                # ...or the segment OPENS with the flag. split_segments cuts
                # at `;`, which is exactly how a find action ENDS, so a second
                # action begins a segment of its own with no `find` in front
                # of it. The selection is then unreadable, which _find_selects
                # answers by refusing - the same inversion, one level up.
                if _reads_as(tok, DISPATCH) \
                        and (_matches_tok(seg_head or chr(0), DISPATCHERS) or j == 0):
                    # `-exec {}` runs the file that was FOUND, so the pattern
                    # that selected it is what names the command.
                    if _exec_placeholder(toks, j) \
                            and _find_selects(toks, TRUNCATE_SET, j):
                        return True
                    cmd_pos = True               # `find . -exec truncate ...`
                    continue
                # A token CLOSING a construct is followed by a command word: a
                # case pattern (`x) truncate`), a function header (`f(){
                # truncate`), a group (`{ truncate`). Catching the shape rather
                # than naming each keyword also covers `esac`/`;;` spellings.
                #
                # A trailing `)` alone is ambiguous: `$(printf x)` (a completed
                # command substitution, already ONE token after shlex) also ends
                # in `)`, but is not a construct closer - the token that follows
                # it is an ordinary OPERAND, not a command word. A genuine closer
                # like `x)` carries an unmatched `)` (no earlier `(` in the same
                # token); a self-contained substitution is parenthesis-balanced.
                #
                # A token that is ONLY grouping punctuation is checked FIRST and
                # by identity: `word` is computed with lstrip("({"), which turns
                # a standalone `(` into the EMPTY string - matching nothing above
                # and then falling through to consume the command slot. That is
                # how `( truncate -s 0 f )` escaped: a REGRESSION against the
                # bare-word rule this file replaced, which caught it as text.
                if tok in ("(", ")", "{", "}", ";;"):
                    cmd_pos = True
                    continue
                # A trailing `)` closes a construct UNLESS the token is a
                # command SUBSTITUTION, which is self-contained and yields an
                # OPERAND. Parenthesis BALANCE cannot tell them apart: bash
                # allows a leading `(` on a case pattern, so `(x)` is balanced
                # and is still a closer. Presence of a substitution opener is
                # what actually distinguishes them.
                # A trailing `)` closes a construct UNLESS the whole token IS
                # a complete command substitution, which yields an OPERAND.
                # Merely CONTAINING one is not enough - `x$(true))` is a case
                # pattern - and parenthesis balance alone is not either, since
                # bash allows a leading `(` on a pattern.
                # A whole substitution leaves the position UNCHANGED rather
                # than consuming it: unquoted, it can expand to nothing at all,
                # and then the NEXT token is the command word - `$(true)
                # truncate -s 0 f` really does run truncate. At an operand
                # position it is simply an operand, so preserving is right in
                # both directions.
                if _whole_substitution(tok):
                    continue
                # A token made of NOTHING but expansions vanishes when they are
                # empty, so it never held command position at all: with no
                # positional parameters `$@ truncate ...` simply runs truncate.
                # Consuming the slot for it read the real command word as an
                # operand. Preserving the slot is also the safe direction when
                # the expansion is NOT empty - the word is unreadable either way.
                if cmd_pos and not word and _expansion_only(tok):
                    continue
                # A command word TORN across a substitution cannot be read at
                # all - its halves are in different tokens - so refuse it here
                # rather than teach EXPANSION the nested-substitution grammar.
                # An ASSIGNMENT is exempt: `T=$(mktemp -d)` tears in exactly the
                # same place, holds no command slot, and is the safe-artifact
                # binding this guard goes out of its way to stay quiet about.
                # ...and so is an OPTION: a backtick has no distinct closing
                # character, so the TAIL of a torn one (`-d` plus a backtick)
                # looks exactly like its head, and an option was never going to
                # be the command word in the first place.
                if cmd_pos and _torn_substitution(tok) \
                        and not tok.startswith("-") \
                        and not _assign_prefix(tok, word):
                    return True
                if tok.endswith(("{", ";;", ")")):
                    cmd_pos = True
                    continue
                if _assign_prefix(tok, word):
                    continue                     # VAR=val prefix
                if cmd_pos and _matches_tok(tok, WRAPPERS):
                    # A wrapper hides the command word behind its own options AND
                    # THEIR ARGUMENTS (`sudo -u root`, `env -u FOO`, `timeout 5`,
                    # `nice -n 10`). Skipping that correctly needs an arity table
                    # per wrapper, which fails OPEN wherever it is wrong — so once
                    # a wrapper holds the slot, ANY later token in the segment
                    # counts. `sudo grep -F truncate f` then over-warns: the safe
                    # direction, and rare next to a wrapped truncate.
                    # `break`, never `return False`: chunks_and_truncation
                    # expands nested payloads (`env -S`, `bash -c`) into FURTHER
                    # chunks, and returning here would abandon them unexamined —
                    # which is exactly how the #519 `env -S` case slipped through.
                    # A later token can also CARRY a command string rather than
                    # be one: `xargs sh -c "truncate -s 0 f"` is one quoted token
                    # after shlex, so an exact-token match reads it as an operand.
                    # Re-enter on any token holding whitespace — that is a payload
                    # to parse, and the recursion terminates because a token
                    # without whitespace never re-enters.
                    for k, t in enumerate(toks[j + 1:], j + 1):
                        # A wrapper does not hide a DISPATCHER - see the SQL
                        # walk above for why the tail scan alone lost it.
                        if _reads_as(t, DISPATCH) \
                                and _exec_placeholder(toks, k) \
                                and _find_selects(toks, TRUNCATE_SET, k):
                            return True
                        # An ASSIGNMENT is data even here - see the SQL walk.
                        # From the RAW token otherwise: _cmd_word strips the `{`
                        # that OPENS `{truncate,truncate}`.
                        if ASSIGN_PREFIX.match(t.lstrip("({")):
                            pass
                        elif _matches_tok(t, TRUNCATE_SET) \
                                or any(_matches_tok(f, TRUNCATE_SET)
                                       for f in _brace_forms(t)):
                            return True
                        if _has_payload(t) and has_truncate([t]):
                            return True
                        # A wrapper OPTION can carry an executable VALUE:
                        # `ssh -o ProxyCommand=...` runs it through a shell.
                        # A PAYLOAD is required - see the SQL walk above: a bare
                        # `env NOTE=truncate echo ok` is data, not a command.
                        if "=" in t and _has_payload(t) \
                                and has_truncate([t.split("=", 1)[1]]):
                            return True
                        # ...and an EXEC-VALUED option needs no payload at all:
                        # its value IS the command word by definition.
                        if any(t.startswith(o + "=") for o in EXEC_VALUE_OPTS) \
                                and _matches_tok(t.split("=", 1)[1], TRUNCATE_SET):
                            return True
                    break
                if cmd_pos:
                    seg_cmd = word
                    if seg_head is None:
                        # The RAW token, so the dispatcher test reads it with
                        # the same rejoin the destructive names get: an empty
                        # expansion in `f${EMPTY}ind` left seg_head as `f`, and
                        # the `-exec` behind it was never treated as a dispatch.
                        seg_head = tok
                cmd_pos = False                  # a real command word, not truncate
    return False


def unsafe(chunks, truncated):
    # Takes the ALREADY-EXPANDED chunks: chunks_and_truncation is documented
    # below as potentially exponential and shares the 3s alarm with everything
    # else here, so it runs exactly once per command and both scanners read the
    # same result.
    #
    # #377 residual 1: a recursive rm wrapped deeper than _all_chunks expands was
    # never surfaced, so this function cleared a command it had not fully read.
    # Warn on the truncation itself — the PRECISE fail-closed condition
    # ("extraction hit its bound with payloads left"), reported by the traversal
    # itself rather than guessed at from the raw text.
    if truncated:
        return True
    for chunk in chunks:
        for seg_idx, (_op, seg) in enumerate(split_segments(chunk)):
            try:
                toks = shlex.split(_fold_ansi_c(seg), posix=True)
            except ValueError:
                toks = seg.split()
            for i, tok in enumerate(toks):
                # basename match so `env rm`, `sudo rm` and /bin/rm all count;
                # lstrip the shell grouping punctuation `(`/`{` so a grouped
                # command like `(rm -rf /etc)` still exposes its command word.
                # lower() because a case-insensitive filesystem (macOS default)
                # runs `RM` as /bin/rm — matches CMD_LOWER + the grep fallback.
                # _spells, not an inline basename: an EMPTY expansion splits the
                # name into halves that rejoin when it expands to nothing, and a
                # basename comparison read `r${EMPTY}m` as a word in no set.
                # _matches_tok, not _spells: at this point the token is a
                # candidate COMMAND word, and `/bin/r?` reaches the real binary
                # while spelling a name in no set.
                #
                # KNOWN over-warn, tracked as issue #585: this loop reads EVERY
                # token as a candidate command word, unlike the cmd_pos-gated
                # caller above, so a glob OPERAND is read as a command name too.
                # `grep SQ*SQ -r src` prompts, because `*` fnmatches `rm` and a
                # recursive flag sits in the same argv. Do not "fix" it by
                # dropping pure-wildcard tokens: `/bin/*` reduces to the same
                # bare `*` and IS a real command word, so that trade buys a
                # false negative. The fix is command-position gating, which
                # belongs in its own change - this is an over-warn on an
                # advisory guard, the safe direction.
                if not _matches_tok(tok, RM_SET) \
                        and not any(_matches_tok(f, RM_SET)
                                    for f in _brace_forms(tok)):
                    continue
                # An expansion supplies the field separators, so a token can
                # carry the WHOLE argv: `${IFS}rm${IFS}-rf${IFS}/etc` is one
                # token here and `-rf` never reached recursive_targets.
                fields = [f for f in _expansion_fields(tok) if f]
                # ...and every OPTION token too. `rm $(true)-rf /etc` reads as
                # a recursive delete once the substitution vanishes, and leaving
                # the rest raw meant the flag never registered. But only the
                # STRIPPED spelling decides option-vs-operand here — the RAW
                # spelling still travels alongside it into recursive_targets,
                # which hands the raw form back for anything it classifies as
                # a target. Collapsing an operand to its stripped form erased
                # a genuine `$VAR` prefix before is_safe() ever saw
                # it, so `${P}out` cleared as the always-relative-safe `out`
                # instead of the unexpanded, unproven path it actually is.
                raw_rest = toks[i + 1:]
                stripped_rest = [_strip_expansions(t) or t for t in raw_rest]
                if len(fields) > 1:
                    # tok itself only exists post-expansion (the whole argv
                    # rode in on one substitution) - there is no "raw" form of
                    # a field to preserve, so structural and raw are the same.
                    argv = [(f, f) for f in fields] \
                        + list(zip(stripped_rest, raw_rest))
                else:
                    argv = [(toks[i], toks[i])] \
                        + list(zip(stripped_rest, raw_rest))
                recursive, targets = recursive_targets(argv)
                # A recursive rm with NO visible literal target takes its targets
                # from elsewhere (xargs/stdin, "$@", a glob, a variable), e.g.
                # `... | xargs rm -rf` — we cannot prove those are safe artifacts,
                # so warn. Otherwise warn iff any listed target is non-safe.
                if recursive and (not targets
                                  or any(not is_safe(t) for t in targets)):
                    return True
    return False


# SCOPE (advisory guard, fails-open by design). This judges every rm the
# structured scan REACHES: chains, wrappers, command AND process substitutions
# (via gitcmd_detect._all_chunks), operands before or after the flag, and a
# targetless recursive rm. Plus, since #377, it warns when extraction itself was
# TRUNCATED — a command wrapped deeper than _all_chunks expands is no longer
# silently cleared, because "I could not read all of it" is not "it is safe".
#
# A payload behind a CONTROL KEYWORD (`if true; then eval <payload>; fi`) is at
# the detector level in _command_argv (the shell-reserved-word stripping added in
# #426), which defeated the fail-CLOSED commit/PR/merge gates too — a far bigger
# deal than this advisory guard. This guard shares _shell_payloads → _command_argv,
# so it sees through keywords for free.
#
# PERMANENT LIMITATIONS (decided in #377, not deferred work — do not reopen as a
# raw-text backstop; that family drew a fresh adversarial finding on all ~12
# iterations in #376):
#   - a recursive rm carried by a NON-shell interpreter (python -c, perl -e).
#     This is a SHELL-structure guard; modelling arbitrary interpreter semantics
#     is out of scope by design.
#   - ANSI-C quoted spellings of the command word (the dollar-single-quote form,
#     e.g. rm spelled as dollar-quote-rm-quote). shlex yields a different token.
#   - a command word held in a VARIABLE, e.g. cmd=truncate then "$cmd" -s 0 f.
#     Resolution for this WAS built and then removed deliberately: it means
#     emulating bash assignment semantics (export/declare/typeset/readonly,
#     stacked and interleaved, both option polarities, which options assign
#     versus print), and every rung of that ladder produced a fresh adversarial
#     finding while silencing none of the 237 measured prompts. Do not reopen it
#     for the same reason #377 closed the raw-text backstop: the scanner reads
#     command POSITION, not values.
# All are exotic and, this guard being advisory (it prompts, never blocks),
# non-blocking; the grep fallback below still catches many of them in the
# python-absent path.


_cmd = sys.stdin.read()
# Bound the scan. _all_chunks expands nested command substitutions with an
# exponential over-count (accepted in #426), and the #377 truncation collector
# runs the boundary extractors on top — a pathologically deep `$(...)` command
# could make this PreToolUse hook slow. Cap wall time with SIGALRM and, on
# timeout, WARN (the safe direction for an advisory guard: "could not finish
# analyzing" is not "safe"). Signals are Unix-only, which is fine for this hook.
import signal


def _on_timeout(signum, frame):
    raise TimeoutError


try:
    signal.signal(signal.SIGALRM, _on_timeout)
    signal.alarm(3)
except (ValueError, AttributeError):
    pass  # no SIGALRM (non-Unix / non-main-thread) — run unbounded, fail-open trap still applies
try:
    _chunks, _truncated = chunks_and_truncation(_cmd)
    verdict = "unsafe" if unsafe(_chunks, _truncated) else "safe"
    # Same single pass, same bound: a second interpreter spawn on every Bash
    # call is what the SINGLE PASS note above exists to avoid.
    trunc = "truncate" if has_truncate(_chunks) else "notruncate"
    sqlc = "sqlclient" if has_sql_client(_chunks) else "nosqlclient"
    # The SQL KEYWORD, read the way bash reads it. The bash arm below used to
    # grep the raw command for it, which `TR"UNC"ATE users` walks straight past:
    # quoting is invisible to a text match but not to the shell. Quotes and
    # backslashes are removed here for the same reason they are in the command
    # word - bash strips them before the word exists.
    # ACCEPTED OVER-WARN: backslashes are removed without tracking quote state,
    # which shlex has already discarded, so `psql -c SQ TRUN\CATE users SQ` -
    # invalid SQL, since a backslash is literal inside single quotes - reads as
    # the keyword and warns. The opposite choice loses `TR\UNC\ATE`, a real
    # destructive spelling; over-warning is the documented direction here.
    #
    # ACCEPTED LIMIT: removing an expansion assumes it yields NOTHING, so
    # `C=C; psql -c "TRUN${C}ATE users"` still reads as `trunate`. Resolving the
    # VALUE is the variable-resolution ladder this file has already deleted
    # twice, and the raw-grep rule that preceded this verdict missed the same
    # command for the same reason - it is not a regression, it is the same
    # unresolved indirection recorded with the other limits.
    #
    # An expansion can also SPLIT the keyword rather than hide it:
    # `TRUN${EMPTY}CATE` rejoins once it expands to nothing. Removing simple
    # expansions lets the literal fragments meet. Deliberately NOT the same as
    # returning sqlop for any expansion beside a client - that would fire on
    # every `psql -c "$QUERY"`, which names no operation at all.
    # ACCEPTED LIMIT, OUT OF SCOPE here: a script fed to an interpreter through
    # stdin or a here-string (`... | bash`, `bash <<< ...`) is not among the
    # chunks at all, so neither scanner sees it. That is chunk EXTRACTION, in
    # the shared gitcmd_detect library, and it is issue #557 - being fixed in
    # its own worktree. Closing it here would mean editing that library
    # concurrently with the change that owns it.
    # From the RAW command, not the chunks: chunks_and_truncation drops a
    # QUOTED heredoc body as inert shell data, and `psql <<SQ SQL SQ ... SQ` is
    # exactly where the statement lives. Harmless here - the keyword only
    # matters when a client also runs.
    _sqlraw = _fold_ansi_c(_cmd + " " + " ".join(_chunks)).lower()
    _sqltext = QUOTING.sub("", _sqlraw)
    # The SAME text with the quoting turned into a SPACE rather than deleted.
    # Deleting is what lets `TR"UNC"ATE` rejoin, and it is also what glues an
    # ATTACHED short option to the keyword: a psql -c whose quoted query starts
    # with no space between them collapses to `-ctruncate`, where the word
    # boundary the search needs no longer exists. The two readings answer
    # opposite halves of the same question, so both are searched rather than one
    # being chosen over the other.
    _sqlspaced = QUOTING.sub(" ", _sqlraw)
    # Split the RAW text on UNESCAPED whitespace and strip the quoting only
    # afterwards, exactly as the client prefilter does. Stripping first leaves a
    # bare space where an escaped one stood, which tore `TRUN{C,C\ }ATE` into
    # pieces no brace form could rejoin.
    _sqlforms = " ".join(
        QUOTING.sub("", f)
        for w in UNESCAPED_SPACE.split(_strip_expansions(_sqlraw))
        for f in _brace_forms(w))
    # The client-INDEPENDENT phrase, read the same normalised way. The bash arm
    # grepped raw text for it, so `TR"UNC"ATE\ TABLE\ users` reached an
    # unlisted client untouched - the very residual the allowlist limit below
    # says this backstop covers.
    _sqlreadings = (_sqltext, _strip_expansions(_sqltext), _sqlforms,
                    _sqlspaced, _strip_expansions(_sqlspaced))
    sqltab = "sqltable" if any(TRUNCATE_TABLE.search(t)
                               for t in _sqlreadings) else "nosqltable"
    # A GLOB in the query text spells the keyword only after pathname expansion
    # (`TRUNCAT?` reaches it when a file named `TRUNCATE users` sits in the
    # working directory), and a word-boundary search finds nothing. fnmatch
    # answers it exactly - but only for a pattern carrying a LITERAL letter: a
    # bare `*` matches every name there is, and `SELECT * FROM t` is the most
    # ordinary query in the language. What that leaves unread is a pattern
    # spelled ENTIRELY in wildcards, the same residual the density rule left on
    # the command-word side and for the same reason.
    _sqlglob = any(_matches(GLOB_BRACKET.sub("?", w), TRUNCATE_SET)
                   for w in UNESCAPED_SPACE.split(_sqlforms)
                   if any(c.isalpha() for c in GLOB_BRACKET.sub("", w)))
    sqlop = "sqlop" if _sqlglob or any(TRUNCATE_WORD.search(t)
                                       for t in _sqlreadings) else "nosqlop"
except Exception:
    # Conservative on every axis. Computing sqlc AFTER this block would raise
    # UnboundLocalError here (_chunks never got assigned), the scanner would
    # print nothing, and the whole verdict would silently degrade to raw grep.
    #
    # EVERY exception, not just the SIGALRM TimeoutError this handler was
    # written for. A parser fault is the same event as a timeout - the scan did
    # not finish - but it used to end the process instead, and the bash arm
    # reads a missing verdict as "no python3" and falls back to grepping the RAW
    # text, which `tr"unc"ate` walks straight past. One malformed escape was
    # therefore a general bypass primitive rather than a bug in one word. This
    # is the fail-CLOSED answer, so a future parser fault costs a prompt rather
    # than the whole check; it is deliberately NOT a reason to stop fixing the
    # faults themselves.
    verdict, trunc, sqlc, sqlop, sqltab = (
        "unsafe", "truncate", "sqlclient", "sqlop", "sqltable")
finally:
    try:
        signal.alarm(0)
    except (ValueError, AttributeError):
        pass
print(verdict, trunc, sqlc, sqlop, sqltab)
' 2>/dev/null || true)
  read -r RM_VERDICT TRUNC_VERDICT SQL_VERDICT SQLOP_VERDICT SQLTAB_VERDICT <<<"$_SCAN_OUT" || true
  # The auto-mode stand-down, applied to the ONE classifier it was written for.
  # "safe", not empty: an empty verdict means the scanner did not run, and the
  # recursive-rm grep fallback below is armed by exactly that.
  # An `if`, not `[[ ]] &&`: under `set -e` a false test as the last command of
  # this block returns non-zero, trips the ERR trap, and fails the guard OPEN.
  if [[ "$AUTO_MODE" == 1 ]]; then
    RM_VERDICT="safe"
  fi
fi

if [[ "$AUTO_MODE" == 0 && "$RM_VERDICT" != "unsafe" && "$RM_VERDICT" != "safe" ]]; then
  # The scanner did not run (no python3, import failure, crash). Do NOT treat a
  # missing verdict as safe — drop the safe-artifact carve-out and warn on any
  # recursive rm. Over-warning is the safe direction for an advisory guard.
  # ponytail: grep, not a bash port of split_segments; revisit only if a
  # python3-less host ever actually matters.
  # Match a recursive rm crudely but broadly (this path is the degraded, no-
  # python fallback, so it biases hard toward warning): case-insensitive so -Rf
  # counts, and allowing quotes/backslashes/whitespace between the rm word and
  # the flag so "rm" -rf and env rm -Rf still trip. Over-warning is the safe
  # direction here.
  if printf '%s' "$CMD" | grep -qiE 'rm[^|;&]{0,20}(-[a-z]*r|--r)' 2>/dev/null; then
    RM_VERDICT="unsafe"
  fi
fi

# --- Destructive pattern checks (first match wins) ---
WARN=""

# rm -rf / rm -r / rm --recursive (non-safe targets)
if [[ "$RM_VERDICT" == "unsafe" ]]; then
  WARN="Destructive: recursive delete (rm -r). This permanently removes files."
fi

# DROP TABLE / DROP DATABASE
if [[ -z "$WARN" ]] && printf '%s' "$CMD_LOWER" | grep -qE 'drop\s+(table|database)' 2>/dev/null; then
  WARN="Destructive: SQL DROP detected. This permanently deletes database objects."
fi

# TRUNCATE — the OPERATION, never the english word.
# A bare `\btruncate\b` over the whole command matched the word wherever it
# appeared: in a grep pattern, in a python string literal, in prose inside an
# echo. Measured over ~/.claude/watch-hooks.log (176 real Bash permission
# prompts, six days) this rule fired 20 times — 11% of EVERY prompt — and not
# one of the 20 was SQL. All 20 were this repo's own gate tests naming the word.
#
# The fix is precision, not relaxation: the rule keeps warning on both things it
# can legitimately mean, and goes silent only where it meant nothing at all.
#   SQL       -> `TRUNCATE TABLE`, or `truncate` alongside a SQL client
#   coreutils -> `truncate` at command-word position (erases a file in place)
#
# KNOWN LIMIT, accepted: the client list is an allowlist and allowlists of
# third-party binaries are never complete — a bare `TRUNCATE users` through a
# client not named here goes unwarned, where the old bare-word rule warned.
# `TRUNCATE TABLE` is the client-independent backstop and covers the spelling
# most tools emit; the residual is bare-TRUNCATE through an unlisted client.
# Add names here as they come up rather than reverting to the bare word, which
# cost 11% of ALL prompts in false positives.
#
# The KEYWORD comes from the scanner (SQLOP_VERDICT), which reads it the way
# bash does: `TR"UNC"ATE users` is TRUNCATE once quoting is applied, and a raw
# grep on the command text never sees it. The grep survives only as the
# scanner-absent fallback, where over-warning is the required direction.
#
# `truncate table` is matched WHEREVER it appears, including inside a quoted
# string, and that is deliberate: it is the operation phrase, not the english
# word, and `psql -c "TRUNCATE TABLE t"` puts real SQL inside quotes too. So
# `echo "do not truncate table users"` over-warns. Accepted — over-warning is
# this guard's safe direction, the phrase is rare in prose (0 of the 20 measured
# false positives were it, all 20 were the bare word), and the alternative —
# requiring a client — would go silent on a bare `TRUNCATE TABLE users;`.
# Deliberately NOT gated on AUTO_MODE, same as DROP above: the classifier does
# not name either, so both stay live in every mode.
if [[ -z "$WARN" ]]; then
  if [[ "$SQLTAB_VERDICT" == "sqltable" ]] \
     || { [[ -z "$SQLTAB_VERDICT" ]] \
          && printf '%s' "$CMD_LOWER" | grep -qE 'truncate[[:space:]]+table\b' 2>/dev/null; } \
     || { { [[ "$SQLOP_VERDICT" == "sqlop" ]] \
          || { [[ -z "$SQLOP_VERDICT" ]] \
               && printf '%s' "$CMD_LOWER" | grep -qE '\btruncate\b' 2>/dev/null; }; } \
          && { [[ "$SQL_VERDICT" == "sqlclient" ]] \
               || { [[ -z "$SQL_VERDICT" ]] \
                    && printf '%s' "$CMD_LOWER" \
                       | grep -qE '\b(psql|pgcli|mysql|mysqlsh|mycli|mariadb|sqlite3|litecli|sqlcmd|sqlplus|snowsql|usql|clickhouse-client|clickhouse|duckdb|cockroach|cqlsh|beeline|trino|presto|impala-shell|spark-sql|bq)\b' 2>/dev/null; }; }; }; then
    WARN="Destructive: SQL TRUNCATE detected. This deletes all rows from a table."
  # Command-word detection is delegated to the quote-aware scanner above
  # (has_truncate), not grepped. Every regex attempt here was bypassable in one
  # direction or false-positive in the other: keying on flags missed
  # `truncate audit.log -s 0` (GNU permutes options after operands), and keying
  # on position missed `sudo truncate` / `/usr/bin/truncate` / the `env -S`
  # audit-log erasure #519 tests for — while any text match fired on
  # `grep -F 'truncate -s'`. shlex resolves both at once.
  #
  # The fallback fires only when the scanner did NOT run (no python3, an import
  # failure, or a crash). Auto mode does NOT reach it: the scanner runs in every
  # mode and the stand-down applies to RM_VERDICT alone. On the degraded path the
  # original broad bare-word match is restored deliberately, because that path
  # must over-warn rather than under-detect.
  elif [[ "$TRUNC_VERDICT" == "truncate" ]] \
       || { [[ "$TRUNC_VERDICT" != "notruncate" ]] \
            && printf '%s' "$CMD_LOWER" | grep -qE '\btruncate\b' 2>/dev/null; }; then
    WARN="Destructive: truncate empties a file in place."
  fi
fi

# The four git patterns below are all named in auto mode's own default block list,
# so each is gated on AUTO_MODE=0 — see the stand-down note above. The SQL checks
# are deliberately NOT gated: the classifier does not name DROP/TRUNCATE.

# git push --force / git push -f (but NOT --force-with-lease which is the safe alternative)
if [[ -z "$WARN" && "$AUTO_MODE" == 0 ]] && printf '%s' "$CMD" | grep -qE 'git\s+push\s+.*(-f\b|--force\b)' 2>/dev/null && ! printf '%s' "$CMD" | grep -qE -- '--force-with-lease' 2>/dev/null; then
  WARN="Destructive: git force-push rewrites remote history."
fi

# git reset --hard
if [[ -z "$WARN" && "$AUTO_MODE" == 0 ]] && printf '%s' "$CMD" | grep -qE 'git\s+reset\s+--hard' 2>/dev/null; then
  WARN="Destructive: git reset --hard discards all uncommitted changes."
fi

# git checkout . / git restore . (standalone . only, not .gitignore etc)
if [[ -z "$WARN" && "$AUTO_MODE" == 0 ]] && printf '%s' "$CMD" | grep -qE 'git\s+(checkout|restore)\s+\.(\s|$)' 2>/dev/null; then
  WARN="Destructive: discards all uncommitted changes in the working tree."
fi

# git clean -f (removes untracked files)
if [[ -z "$WARN" && "$AUTO_MODE" == 0 ]] && printf '%s' "$CMD" | grep -qE 'git\s+clean\s+.*-[a-zA-Z]*f' 2>/dev/null; then
  WARN="Destructive: git clean -f removes untracked files permanently."
fi

# --- Output ---
if [[ -n "$WARN" ]]; then
  WARN_ESCAPED=$(printf '%s' "$WARN" | sed 's/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"[careful] %s"}}\n' "$WARN_ESCAPED"
else
  echo '{}'
fi
