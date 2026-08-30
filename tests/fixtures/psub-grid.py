"""Generated coverage for the #563 process-substitution rule, over the axes the parser
actually touches: transport x wrapper x quoting/escaping, in BOTH directions.

ACTIVE compositions must block. Most really do feed a shell a program; two spellings in the
set do NOT and are labelled where they appear -- `2> >(receiver)` redirects stderr while the
payload goes to stdout, and `payload >(receiver)` passes the substitution pathname as an
argument. They are kept as OVER-BLOCK pins: the classifier must still answer them
conservatively, but they do not demonstrate the transport invariant.
INERT twins must stay allowed: same shape, harmless body, no write verb anywhere -- this is
the arm that catches a rule widened until it blocks everything.

Prints one summary line. Asserted in-process rather than through the gate because the gate
has its own whole-command checks that would mask what this rule did.
"""
import sys

sys.path.insert(0, "hooks/gate-scripts/lib")
import cmdword  # noqa: E402

SQ, DQ = chr(39), chr(34)
PAD = ": %s$(printf %s%s%s)%s" % (DQ, SQ, DQ, SQ, DQ)   # a quoted substitution, both sides

# (template, active-body, inert-body). `%s` is where the body goes.
TRANSPORTS = [
    ("bash < <(%s)", "printf 'rm -rf src'", "printf hello"),
    ("bash <(%s)", "printf 'rm -rf src'", "printf hello"),
    ("cat < <(%s) | bash", "printf 'rm -rf src'", "printf hello"),
    # an ESCAPED receiver: the shell strips the backslashes before resolving the command
    # word, so no contiguous `bash` appears in the text as written.
    ("cat < <(%s) | b" + chr(92) + "a" + chr(92) + "s" + chr(92) + "h",
     "printf rm" + chr(92) + " -rf" + chr(92) + " src", "printf hello"),
    ("printf 'rm -rf src' > >(%s)", "bash", "cat -n"),
    # RESIDUAL over-block, not a transport: `2>` redirects STDERR while printf writes on
    # stdout, so the payload never reaches the receiver. It blocks because `>(...)` takes
    # the whole command as its producer -- conservative, and worth pinning as such rather
    # than dressing up as an active case.
    ("printf 'rm -rf src' 2> >(%s)", "bash", None),
    # ACTIVE-ONLY: its inert twin still carries a `> ""` write redirect, which really is
    # a write -- the classifier is right to block it, so it is not a precision case.
    ("printf 'rm -rf src' > %s%s>(%s)" % (DQ, DQ, "%s"), "bash", None),
]
# Each wrapper must preserve the composition. `%s` is the command.
WRAPPERS = [
    "%s",
    "true; %s",
    "%s; true",
    "{ %s; }",
    "( %s )",
    PAD + "; %s; " + PAD,
    "if true; then %s; fi",
]

bad = []
n = 0
for tmpl, active, inert in TRANSPORTS:
    for wrap in WRAPPERS:
        n += 1
        live = wrap % (tmpl % active)
        if not cmdword.is_file_mod(live):
            bad.append("allowed active: " + live)
        if inert is None:
            continue
        n += 1
        # the inert twin drops the write verb everywhere it appears
        harmless = (wrap % (tmpl % inert)).replace("printf 'rm -rf src'", "printf hello")
        if cmdword.is_file_mod(harmless):
            bad.append("blocked inert: " + harmless)

# PRECISION, separately: a `.sh`/`.log` OPERAND is not a receiver. A `\\b` boundary made
# `sh` match `notes.sh`, which is the quoted-operand false positive #519 exists to remove.
# VERSION-QUALIFIED receivers, which are a separate set from the exact names: the pattern
# that answers them is END-ANCHORED, because it is normally asked of one word, so searching
# it across a whole command matched nothing.
for _live in ("cat < <(printf 'system \"rm -rf src\"') | /usr/bin/perl5.34",
              "cat < <(printf 'os.system(\"rm -rf src\")') | python3.12"):
    n += 1
    if not cmdword.is_file_mod(PAD + "; " + _live + "; " + PAD):
        bad.append("allowed active: " + _live)

# COMMAND-POSITION-only receiver classes, asserted WITHOUT the pads -- which is where they
# are answered, by the lexed path that anchors them to command position. Behind the pads
# they join the adversarial-quoting residual pinned below: matching them quote-blind is the
# any-word test ADR 0032 measured at 100 over-blocks for `.` alone and rejected.
for _recv in ("source /dev/stdin", ". /dev/stdin", "unshare", "script -q /dev/null",
              "lldb-19", "su"):
    n += 1
    _live = ("cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src" + chr(92) + ";) | "
             + _recv)
    if not cmdword.is_file_mod(_live):
        bad.append("allowed active: " + _live)

# ...and the substitution as the SOURCED operand, which needs no pipe at all.
n += 1
if not cmdword.is_file_mod(". <(printf 'rm -rf src')"):
    bad.append("allowed active: . <(payload)")

# PRECISION for that same set: these words appear as DATA, and a quote-blind scan for them
# turned every one of these read-only greps into a block.
# BOUNDARY PLACEMENT: a quote or a backslash inside an operand is deleted by the shell
# before it resolves anything, so it must not act as a name boundary. Asked of the RAW text
# these each matched and turned a read-only grep into a block; the scan asks the DEQUOTED
# variants instead, where they are ordinary filenames.
# ATTACHED REDIRECTS and richer word punctuation: a redirection needs no whitespace, so
# `source</dev/stdin` is one word; and `:`/`@`/`=` belong to a WORD, not to a boundary.
for _live in ("source</dev/stdin", ".</dev/stdin", "lldb-19</dev/stdin",
              "unshare</dev/stdin", "command>/dev/null source /dev/stdin"):
    n += 1
    _cmd = ("cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src" + chr(92) + ";) | "
            + _live)
    if not cmdword.is_file_mod(PAD + "; " + _cmd + "; " + PAD):
        bad.append("allowed active (attached redirect): " + _cmd)

# IDENTITY vs INDEX: CPython interns short strings, so a leading `!` prefix and a trailing
# truncated `!` are the SAME object. `w is _last_word` fired on the leading one and blocked
# a read-only grep; the check compares positions now.
#
# This case DOES discriminate, measured rather than assumed: rebuilding the module with the
# identity comparison restored classifies it True, the index comparison False. (Comparing
# against the pre-feature commit proves nothing -- the cut check does not exist there at
# all, so it allows for an unrelated reason.)
#
# ...and an ASSIGNMENT is never the command word, so an expansion in its VALUE says nothing
# about what runs.
for _inert in ("! grep -n 'rm -rf src' !{a,b} <(echo pat)",
               "! grep -n 'rm -rf src' <(echo pat)",
               "X=foo{a,b} grep -n 'rm -rf src' <(echo pat)",
               "</tmp/${name} grep -n 'rm -rf src' <(echo pat)",
               "2>/tmp/${name} grep -n 'rm -rf src' <(echo pat)",
               "grep -n 'rm -rf src' foo:bash <(echo pat)",
               "grep -n 'rm -rf src' foo@python3.12 <(echo pat)",
               # a `${VAR}` reference is not a brace EXPANSION -- no `..` and no `,`
               'grep -n "rm -rf src" "${notes}" <(echo pat)',
               "grep -n 'rm -rf src' 'a{b}c' <(echo pat)",
               "grep -n 'rm -rf src <(' notes.txt",
               'grep -n "rm -rf src" bash".log" <(echo pat)',
               "grep -n " + chr(39) + "rm -rf src" + chr(39) + " bash" + chr(92)
               + ".log <(echo pat)",
               'grep -n "rm -rf src" python3".12.log" <(echo pat)'):
    n += 1
    if cmdword.is_file_mod(_inert):
        bad.append("blocked inert: " + _inert)

for _inert in ("grep -n 'rm -rf src' <(printf lldb-19)",
               "grep -n 'rm -rf src' <(printf source)",
               "grep -n 'rm -rf src' <(printf unshare)"):
    n += 1
    if cmdword.is_file_mod(_inert):
        bad.append("blocked inert: " + _inert)

# ASSEMBLED receivers: the name is built by an expansion, so NO spelling of the text
# contains it. The lexed path answers these through `_UNRESOLVED_CW_CHARS`, so they block
# WITHOUT the quote pads -- and the pair (assembled AND behind quoting that defeats shlex)
# is a stated residual, asserted below so the line stays visible.
for _recv in ("b$(printf as)h", "$SHELL", "b" + chr(96) + "printf as" + chr(96) + "h"):
    n += 1
    _live = "cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src) | " + _recv
    if not cmdword.is_file_mod(_live):
        bad.append("allowed active: " + _live)

# ADVERSARIAL QUOTING: both faces, behind the pads that defeat every lexed view. These are
# closed by the command-POSITION walk over the raw text -- the anchor is what makes the
# question askable quote-blind without becoming the any-word test.
# COMMAND-POSITION PREFIXES: bash allows assignments, redirections and prefix words in
# front of the real command, so the receiver is not the token after the operator.
for _pre in ("X=1 ", ">/dev/null ", "> /dev/null ", "2> /dev/null ", "command ",
             "env ", "env -i ", "! ", "time ",
             # PATH-QUALIFIED prefixes and the Homebrew `env` spelling
             "/usr/bin/time ", "/usr/bin/env ", "genv ",
             # QUOTED prefix values carry whitespace that a plain split cuts in two
             'X=%sa b%s ' % (DQ, DQ), '> %s/tmp/a b%s ' % (DQ, DQ),
             # ESCAPES join words the same way quotes do
             "X=foo" + chr(92) + " bar ", "X=foo" + chr(92) + ";bar "):
    n += 1
    _live = ("cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src" + chr(92) + ";) | "
             + _pre + "source /dev/stdin")
    if not cmdword.is_file_mod(PAD + "; " + _live + "; " + PAD):
        bad.append("allowed active (prefix): " + _live)

# RESERVED WORDS open or connect a compound command, and the receiver sits inside it.
for _cmp in ("if true; then source /dev/stdin; fi",
             "{ source /dev/stdin; }",
             "while false; do source /dev/stdin; done"):
    n += 1
    _live = ("cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src" + chr(92) + ";) | "
             + _cmp)
    if not cmdword.is_file_mod(PAD + "; " + _live + "; " + PAD):
        bad.append("allowed active (compound): " + _live)

# RESIDUAL over-block (accepted): the separator class is quote-blind, so punctuation inside
# a quoted OPERAND reads as a boundary. Telling a quoted `;` from a real one is the lexed
# question, and being defeated at it is why this walk exists.
for _resid in ('grep -n "rm -rf src; $file" <(echo pat)',
               'grep -n "rm -rf src | source" <(echo pat)'):
    n += 1
    if not cmdword.is_file_mod(_resid):
        bad.append("RESIDUAL now allows (good -- update this pin): " + _resid)

for _resid in ("cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src) | b$(printf as)h",
               "cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src) | $SHELL",
               "cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src) | /bin/ba[s]h",
               "cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src) | /bin/ba?h",
               "cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src" + chr(92)
               + ";) | source /dev/stdin",
               "cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src" + chr(92)
               + ";) | unshare",
               "cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src" + chr(92)
               + ";) | lldb-19"):
    n += 1
    if not cmdword.is_file_mod(PAD + "; " + _resid + "; " + PAD):
        bad.append("allowed active (behind quote pads): " + _resid)
n += 1
if cmdword.is_file_mod('grep -n "rm -rf src" "$file" "<(x)"'):
    bad.append("blocked inert: quoted substitution beside an unrelated expansion")

# ...and a name in a DIRECTORY component is an operand, never the command word. `/` is
# asymmetric in the boundary for exactly this: after a slash it can be the program.
for _inert in ("grep -n 'rm -rf src' bash/notes.txt <(echo pat)",
               "grep -n 'rm -rf src' logs/python3.12/output <(echo pat)",
               'diff <(sort "$A") <(sort "$B")',
               "grep -n 'rm -rf src' notes.sh <(echo pat)",
               "grep -n 'rm -rf src' x.perl5.34 <(echo pat)",
               "grep -n 'rm -rf src' bash.log <(echo pat)",
               "diff <(sort a) <(sort b)",
               "bash <(cat scripts/build.sh)"):
    n += 1
    if cmdword.is_file_mod(_inert):
        bad.append("blocked inert: " + _inert)

# OPERAND-TAKING WRAPPERS put a positional operand between themselves and the command, and
# EXTGLOB command words expand to a shell before one exists -- the run regex splits on `(`,
# so it cannot see the second at all.
# ...while an expansion in the COMMAND word behind an assignment prefix still counts.
n += 1
if not cmdword.is_file_mod("cat < <(printf rm" + chr(92) + " -rf" + chr(92)
                           + " src) | X=1 ba{s..s}h"):
    bad.append("allowed active: assignment prefix before a brace-expanded receiver")

for _live in ("flock /tmp/l unshare", "chroot /r unshare",
              "su root -c :", "/bin/ba+(s)h", "/bin/ba@(s)h",
              # BRACE EXPANSION, which the run regex also splits before the unresolved
              # test can see it
              "ba{s..s}h", "ba{s,z}h", "/bin/{bash,zsh}"):
    n += 1
    _cmd = ("cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src" + chr(92) + ";) | "
            + _live)
    if not cmdword.is_file_mod(PAD + "; " + _cmd + "; " + PAD):
        bad.append("allowed active (wrapper/extglob): " + _cmd)

# RESIDUAL over-block (accepted), and an instance of the rule already stated: a shell named
# ANYWHERE in a command carrying a process substitution puts the whole command under the raw
# scan. `_stage_words` peels a long option value, so `--label=bash` names one. It needs the
# option value to BE a shell name, a substitution, and a write verb in the same command.
n += 1
if not cmdword.is_file_mod("grep -n 'rm -rf src' --label=bash <(echo pat)"):
    bad.append("RESIDUAL now allows (good -- update this pin): --label=bash")

# ── SEEDED PROPERTY, over the grammar rather than the list ───────────────────
# Every defect this rule shipped was a COMPOSITION nobody had enumerated, and a fixed table
# can only ever hold the ones someone thought of. This quantifies instead: 2,000 random
# compositions of transport x receiver x prefix x wrapper x pad, each of which really feeds
# a shell, all of which must block. The seed is fixed, so a failure reproduces exactly.
import random                                                          # noqa: E402

RNG = random.Random(20260830)
# BOTH DIRECTIONS. `%s` is the receiver, `%%s` the payload -- and for the output forms the
# payload is the OUTER command, which is what makes them the mirror image rather than a
# spelling of the same thing.
TRANSPORT_F = ["%s < <(%%s)", "%s <(%%s)", "cat < <(%%s) | %s", "cat < <(%%s) |%s",
               "%%s > >(%s)", "%%s 2> >(%s)", '%%s > "">(%s)', "%%s >(%s)"]   # arg form: see note below
RECEIVERS = ["bash", "sh", "python3", "perl5.34", "source /dev/stdin", ". /dev/stdin",
             "unshare", "lldb-19", "$SHELL", "b$(printf as)h", "/bin/ba[s]h",
             "/bin/ba+(s)h", "ba{s..s}h", "b" + chr(92) + "a" + chr(92) + "s"
             + chr(92) + "h"]
PREFIXES = ["", "X=1 ", "> /dev/null ", ">/dev/null ", "command ", "env ", "env -i ",
            "! ", "time ", "/usr/bin/time ", "genv ", "X=" + chr(92) + "a" + chr(92)
            + " b ", 'X="a b" ']
WRAPS = ["%s", "true; %s", "%s; true", "{ %s; }", "( %s )", "if true; then %s; fi",
         PAD + "; %s; " + PAD]
# NOTE on `%%s >(%s)`: this passes the substitution PATHNAME as an argument rather than
# redirecting into it, so the payload does not reach the receiver either. It is kept in the
# randomised set because the classifier must still answer it conservatively -- but like the
# `2>` case above it is an over-block pin, not a demonstration of the transport invariant.
PAYLOAD = "printf rm" + chr(92) + " -rf" + chr(92) + " src" + chr(92) + ";"

prop_bad = []
for _ in range(2000):
    recv, pre, wrap = RNG.choice(RECEIVERS), RNG.choice(PREFIXES), RNG.choice(WRAPS)
    tf = RNG.choice(TRANSPORT_F)
    # a prefix only makes sense in front of a command word, i.e. on the piped and output
    # forms; the input forms put the receiver first, where a prefix would be the command.
    #
    # The direction is read from where `%s` SITS, not from `tf.split("%s")[0]`: every
    # template also carries the escaped payload placeholder `%%s`, and splitting on `"%s"`
    # matches inside THAT first, returning `"%"` for every output template -- so they never
    # contained a `>` by this test and `pre` was silently dropped, leaving prefixed output
    # receivers unexercised while the comment claimed otherwise.
    _recv = (pre + recv) if ("|" in tf or tf.rstrip().endswith(">(%s)")) else recv
    cmd = (tf % _recv) % PAYLOAD
    cmd = wrap % cmd
    if not cmdword.is_file_mod(cmd):
        prop_bad.append(cmd)
n += 2000
if prop_bad:
    bad.append("property: %d/2000 compositions allowed, first: %s"
               % (len(prop_bad), prop_bad[0]))

# A LINE CONTINUATION between `<` and `(` is removed by bash before parsing, and
# `_normalize` removes it before the scanner runs -- so the substitution is seen. Pinned
# because reading `_process_substitutions` alone suggests otherwise: its backslash skip
# would step over the pair if the continuation ever reached it.
for _payload in ("printf " + chr(39) + "rm -rf src" + chr(39),
                 "printf " + chr(39) + "echo x > src/impl.py" + chr(39)):
    n += 1
    if not cmdword.is_file_mod("bash < <" + chr(92) + chr(10) + "(" + _payload + ")"):
        bad.append("allowed active (line-continuation substitution): " + _payload)

# A COMMAND-POSITION WORD THAT BEGINS WITH AN EXPANSION. The run regex treats `{` as a
# separator, so `{b..b}ash` starts a run with nothing attached before the brace and `_cut`
# -- which asks whether an expansion was glued to a run's LAST word -- cannot see it. It
# blocks anyway, plain and behind the quote pads, because the receiver question has more
# than one answer: the quote-blind name scan and the unresolved-character test both reach
# it. Pinned because reading `_cut` alone suggests a gap.
for _wrap in (lambda x: x, lambda x: PAD + "; " + x + "; " + PAD):
    n += 1
    _live = ("cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src" + chr(92)
             + ";) | {b..b}ash")
    if not cmdword.is_file_mod(_wrap(_live)):
        bad.append("allowed active (brace-leading receiver): " + _live)

# BUDGET EXHAUSTION FAILS CLOSED FOR BOTH HALVES. When the substitution walk runs out it
# yields the whole command as a producer, and the producer loop applies the verb regexes AND
# `_RAW_WRITE_REDIR_RE` -- so a redirect-only payload past the allowance still blocks. Pinned
# because "exhaustion returns [whole]" invites the assumption that only the verb half runs.
n += 1
_huge = ("bash <(printf x) " * 5000 + " ; printf " + chr(39) + "echo x > src/impl.py"
         + chr(39) + " | bash")[:64000]
if not cmdword.is_file_mod(_huge):
    bad.append("allowed active (budget exhaustion + redirect-only payload)")

# A `&` or `|` BELONGING TO A REDIRECTION is not a command separator. The run regex split on
# both unconditionally, losing the pending target and stopping the walk on it -- a fail-open
# behind the quote pads, where the lexed path is already defeated.
for _pre in ("2>&1 ", ">| /tmp/t ", "&>/dev/null ", "2>&1 >| /tmp/t "):
    n += 1
    _live = ("cat < <(printf rm" + chr(92) + " -rf" + chr(92) + " src" + chr(92) + ";) | "
             + _pre + "source /dev/stdin")
    if not cmdword.is_file_mod(PAD + "; " + _live + "; " + PAD):
        bad.append("allowed active (redirect-operator prefix): " + _live)

# ...and a prefix in front of a brace-leading receiver, which `_cut` also cannot see.
n += 1
if not cmdword.is_file_mod(PAD + "; cat < <(printf rm" + chr(92) + " -rf" + chr(92)
                           + " src" + chr(92) + ";) | env {b..b}ash; " + PAD):
    bad.append("allowed active: env {b..b}ash")

# ...but an ESCAPED redirect character must NOT be folded: `\>` is a literal argument, so
# the `|` after it is a real pipeline operator and folding it destroyed the boundary.
n += 1
_esc = ("printf rm" + chr(92) + " -rf" + chr(92) + " src" + chr(92) + "; " + chr(92)
        + "> | source /dev/stdin <(echo pat)")
if not cmdword.is_file_mod(PAD + "; " + _esc + "; " + PAD):
    bad.append("allowed active (escaped redirect then real pipe)")

if bad:
    print("PSUB fail %d/%d" % (len(bad), n))
    for b in bad[:6]:
        print("   " + b)
else:
    print("PSUB ok %d" % n)
