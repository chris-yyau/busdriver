#!/usr/bin/env python3
"""#1093 part 1 rows: writes hidden by a heredoc body must block; read-only controls must allow.

  heredoc_1093.py rows <armed-repo>

Each reproducer is first run under bash >= 5 in a scratch tree and must write (rm src/ or
create src/f). Each control must not write. Both then go through the real hook. Helpers come
from cmdword_1085.py next to this file.
"""
import os, shlex, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmdword_1085 as fx  # noqa: E402

SQ, BT = chr(39), chr(96)
q = shlex.quote
E2 = "cat <<E\nit's\nE\nrm -rf src\ncat <<E2\ndon't\nE2"
UNREADABLE = "cat <<E\nit's\nE\nrm -rf src\necho " + SQ
P19 = "echo x > src/f\necho " + SQ
DQ = "echo x > src/f\necho " + chr(34)
FIND = "find . -maxdepth 0 -exec bash -c "
R46 = 'bash -c "cat <""<E\nit\'s\nE\nrm -rf src\ncat <""<E2\ndon\'t\nE2"'

BLOCK = [
    ("R1 redirect after an apostrophe body", "cat <<E\nit's\nE\necho x > src/f\necho 'y'"),
    ("R2 R1 inside $( )", "v=$(cat <<E\nit's\nE\necho x > src/f\necho 'y'\n)"),
    ("R3 R1 with a comment", "cat <<E\nit's\nE\necho x > src/f # c\necho 'y'"),
    ("R4 R1 with a quoted delimiter", "cat <<'E'\nit's\nE\necho x > src/f\necho 'y'"),
    ("R10 ${v%)} closer in an expanding body", 'cat <<E\n: "$(echo ${v%)}; rm -rf src)"\nE'),
    ("R11 a second body re-closes the quote (#1101 item 4)", E2),
    ("R12 R11 inside $( )", "v=$(" + E2 + "\n)"),
    ("R13 R11 inside bash -c", "bash -c " + q(E2)),
    ("R14 R11 with a redirect", "cat <<E\nit's\nE\necho x > src/f\ncat <<E2\ndon't\nE2"),
    ("R15 redirect in a body $( ) after an apostrophe", "cat <<E\nit's $(echo x > src/f)\nE\necho 'y'"),
    ("R16 redirect in a body backtick after an apostrophe", "cat <<E\nit's `echo x > src/f`\nE\necho 'y'"),
    ("R22 R1 under <<- tab stripping", "cat <<-E\n\tit's\n\tE\necho x > src/f\necho 'y'"),
    ("R29 backtick split by a continuation after an apostrophe", "cat <<E\nit's `\\\necho x > src/f`\nE\necho 'y'"),
    ("R40 ${v#'...'} quotes a fake $( in a body", "cat <<E\necho it's ${v#'$(echo '} $(rm -rf src) ${v#')'} don't\nE"),
    ("R43 a review-script path in the body does not exempt R1",
     "cat <<E\nit's\nsh litmus/scripts/x\nE\necho x > src/f\necho 'y'"),
    ("R44 a write after a body the scan gives up on (K7's body)",
     "cat <<E\nit's ${v#'x'}\nE\necho x > src/f\necho 'y'"),
    # Design review round 1: a body give-up below depth 0, a quote-split `<<`, a lost body.
    ("R45 R40 inside $( )", "v=$(cat <<E\necho it's ${v#'$(echo '} $(rm -rf src) ${v#')'} don't\nE\n)"),
    ("R46 R13 with <\"\"< in a double-quoted program", R46),
    ("R47 a body give-up in a program, then a write main sees",
     "bash -c " + q("cat <<E\nit's ${v#'x'}\nsh litmus/scripts/x\nE\nv=$(echo ${v%)}; echo x > src/f)")),
    ("R48 R47's shape inside $( ), no review path",
     "v=$(cat <<E\nit's ${v#'x'}\nE\nv=$(echo ${v%)}; echo x > src/f)\necho 'y'\n)"),
    ("R49 R44 inside $( )", "v=$(cat <<E\nit's ${v#'x'}\nE\necho x > src/f\necho 'y'\n)"),
    # Design review round 3: a comment continuation, a split body, F8 reading body text.
    ("R50 R11 after a #...\\ comment line", "echo hi # c \\\ncat <<E\nit's\nE\nrm -rf src\ncat <<E2\ndon't\nE2"),
    ("R51 R14 after a #...\\ comment line", "echo hi # c \\\ncat <<E\nit's\nE\necho x > src/f\ncat <<E2\ndon't\nE2"),
    ("R52 $( split by a continuation in a body", "cat <<E\nit's $\\\n(echo x > src/f)\nE\necho 'y'"),
    ("R53 ca\\<nl>se split in a second body", "cat <<A\nit's\nA\ncat <<B\n$(ca\\\nse x in x) echo x > src/f;; esac)\nB\necho 'y'"),
    ("R54 a body's review-script path exempts nothing", "cat <<E\nsh litmus/scripts/x\nE\necho x > src/f"),
    ("R55 R54 with a decoy redirect before the apostrophe",
     "cat <<E\nsh litmus/scripts/x > /tmp/decoy\nit's\nE\necho x > src/f\necho 'y'"),
    ("R56 a quoted )) makes $((...)) a $( ) in a body", "cat <<E\necho it's $((echo '))'); rm -rf src) don't\nE"),
    ("R57 R56 with a redirect", "cat <<E\necho it's $((echo '))'); echo x > src/f) don't\nE"),
    # PR backstop: cutting a heredoc can CREATE an F8 match (`sh ` then the next line).
    ("R58 the cut joins `sh ` to a review-script path", "echo sh <<E\nx\nE\nlitmus/scripts/y; echo x > src/f"),
    ("R59 R58 with bash", "bash <<E\nx\nE\nlitmus/scripts/y; echo x > src/f"),
    # PR backstop: a continuation-split `<\<nl><` still gets the heredoc-free pass.
    ("R60 R1 with a split << and a $ in the body", "cat <\\\n<E\nit's $x\nE\nrm -rf src\necho 'y'"),
    ("R61 R60 with a redirect", "cat <\\\n<E\nit's $x\nE\necho x > src/f\necho 'y'"),
    # Round-6 regressions of the withdrawn unquoted-body join: a `<<` that is no heredoc.
    ("J1 $((1<<2)) before a quoted body", ": \"$(echo $((1<<2))\ncat <<'EE'\nE\\\nE\n)\nEE\nrm -rf src)\""),
    ("J2 # <<EOF before a quoted body", ": \"$(echo # <<EOF\ncat <<'EE'\nE\\\nE\n)\nEE\nrm -rf src)\""),
    ("J3 \"<<EOF \" at top level", "echo \"<<EOF \"\ncat <<'END'\nE\\\nND\nit's\nEND\nrm -rf src\ncat <<'E2'\ndon't\nE2"),
]
ALLOW = [
    ("C1 quoted-delimiter body, no write", "cat <<'E'\nit's\nE\necho 'y'"),
    ("C2 backticks in an unquoted body", 'printf "%s" "$(cat <<EOF\nUse `echo hi` and it\'s fine\nEOF\n)"'),
    ("C3 $(date) in an unquoted body", "cat <<EOF\nnow: $(date) it's\nEOF"),
    ("C4 ${v%)} in a body", "cat <<E\n${v%)} it's\nE\necho 'y'"),
    ("C5 two bodies, read-only", "cat <<A <<B\nit's\nA\ndon't\nB\necho 'ok'"),
    ("C6 <<- tab stripping, read-only", "cat <<-E\n\tit's\n\tE\necho 'y'"),
    ("C8 bash -c readable heredoc program", "bash -c " + q("echo hi; cat <<E\nit's\nE\necho ok")),
    ("C9 eval readable heredoc program", "eval " + q("cat <<E\nit's\nE\necho ok")),
    ("C10 cut body stays allowed", ': "$(echo ${v%)})"'),
    ("C11 escaped quote in $'...'", "echo $'it\\'s'"),
    ("C12 body then /dev/null", "cat <<E >/dev/null\nit's\nE\necho 'y'"),
    ("C15 quoted delimiter keeps a split terminator literal", "cat <<'EOF'\nit's\nE\\\nOF\nEOF\necho 'y'"),
    ("C16 readable program in a double-quoted $( )", ': "$(bash -c ' + q("echo hi\necho ok") + ')"'),
    ("C17 readable find -exec program", FIND + q("echo hi\necho ok") + " \\;"),
    ("C18 over-cap newline command, no heredoc", "echo " + "a" * 33000 + "\necho b"),
    ("C19 split $( in a body, read-only", "cat <<E\nit's $\\\n(date)\nE\necho 'y'"),
    ("C25 escaped $' in a body backtick is read unescaped", "cat <<E\n`echo \\$'it\\'s'`\nE"),
    ("C27 a review-script redirect is still exempt", "bash skills/litmus/scripts/none.sh > out.log"),
]
# Known allows: they write, and main allows them too. Fixing one fails its row: flip it to BLOCK.
KNOWN_ALLOW = [
    ("O1 comment apostrophe hides a redirect (#1101 item 3)", "# it's\necho x > src/f\necho 'y'"),
    ("O2 one-line program ending in a lone backslash (#1112)", "bash -c " + q("echo x > src/f; echo \\")),
    ("O3 ((true); subshells hide every later heredoc (#1113)",
     "((true); cat <<E\necho it's\nE\nrm -rf src\ncat <<E2\ndon't\nE2\n)"),
    ("O4 $(( ( (1)) << 2 )) read as a heredoc (#1113)",
     "cat <<E\nit's\nE\necho $(( ( (1)) << 2 ))\necho x > src/f\necho 'y'"),
    ("O5 a double quote opened on the <<EOF line (#1113)",
     "true <<EOF \"hello\nEOF\nworld\"\necho it's\nE\\\nOF\necho x > src/f\necho 'y'"),
    ("O6 a ${ opened on the <<E line (#1113)", "echo <<E ${v:-\nE\n}\nit's\nE\nrm -rf src\ncat <<E2\ndon't\nE2"),
    # #1093 members left to later parts.
    ("O7 bash -c program ending in an open quote (#1093 1b)", "bash -c " + q(UNREADABLE)),
    ("O8 bash -c redirect then an open quote (#1093 1b)", "bash -c " + q(P19)),
    ("O9 bash -c redirect then an open double quote (#1093 1b)", "bash -c " + q(DQ)),
    ("O10 O8 inside a double-quoted $( ) (#1093 1b)", ': "$(bash -c ' + q(P19) + ')"'),
    ("O11 find -exec O8 (#1093 1b)", FIND + q(P19) + " \\;"),
    ("O12 R1 behind a UTF-8 byte delimiter (#1093 3)", "cat <<$'E\\xc3\\xa9'\nit's\nEé\necho x > src/f\necho 'y'"),
    ("O13 terminator split by a continuation (#1093)", "cat <<EOF\nit's\nE\\\nOF\necho x > src/f\necho 'y'"),
]
# Known over-blocks, none writes. Fixing one fails its row: move it to ALLOW.
KNOWN_BLOCK = [
    ("K1 two read-only $( ) apostrophe bodies, as on main", "v=$(cat <<E\nit's\nE\necho ok\n)\n" * 2),
    ("K7 a quoted pattern in an expanding body (new, R40)", "cat <<E\nit's ${v#'x'}\nE\necho ok"),
    ("K9 K7 inside a program (new)", "bash -c " + q("cat <<E\nit's ${v#'x'}\nE\necho ok")),
    ("K10 a quoted $(( )) in an expanding body (new)", "cat <<E\nit's $(( '1' + 1 ))\nE\necho ok"),
    ("K8 UTF-8 delimiter in $( ), as on main (#1093 3)", ': "$(cat <<$\'E\\xc3\\xa9\'\nhi\nEé\n)"'),
    ("N1 25 identical $( ) spend the scan budget as on main",
     'echo "' + ("$(echo " + "x " * 200 + ") ") * 25 + '"'),
]


def nest(levels, fill):
    # Each level a heredoc and then a bash -c of the next; read-only throughout.
    prog = "cat <<E\nx\nE\necho " + "a" * fill + "\necho ok"
    for _ in range(levels):
        prog = "cat <<E\nx\nE\nbash -c " + q(prog)
    return prog


def switch_rows():
    """marker_check reads as on main: every new reading is off with the switch off."""
    sys.path.insert(0, fx.LIB)
    import shell_lex
    import cmdword

    def on(f, *a):
        shell_lex._cmdword_on[0] = True
        try:
            return f(*a)
        finally:
            shell_lex._cmdword_on[0] = False
    body = "cat <<E\n: $(rm -rf src) `tee x`\nE\n"
    spans = []
    checks = [
        ("expanding-body substitutions read (on)", on(shell_lex._subst_bodies, body) == (["rm -rf src", "tee x"], True)),
        ("expanding-body substitutions skipped as on main (off)", shell_lex._subst_bodies(body) == ([], True)),
        ("quoted-delimiter body never read (on)", on(shell_lex._subst_bodies, body.replace("<<E", "<<'E'")) == ([], True)),
        ("spans leave the result unchanged", shell_lex._subst_bodies(body, spans) == shell_lex._subst_bodies(body)),
        ("spans: joined text, operator, body", spans == [body, (4, 7), (8, len(body))]),
        ("heredoc_frees cuts operator and body", cmdword.heredoc_frees(body) == ["cat \n"]),
        ("heredoc_frees restores the switch", shell_lex._cmdword_on[0] is False),
        ("heredoc_frees: none without a heredoc", cmdword.heredoc_frees("echo hi") == []),
        # The plain run joins the comment line and sees no heredoc; the copy ends the comment.
        ("heredoc_frees reads the comment-continuation copy",
         cmdword.heredoc_frees("echo # c \\\ncat <<E\nit's\nE\nrm -rf src\n") == ["echo # c  \ncat \nrm -rf src\n"]),
        ("an expanding body is joined before its substitutions are read",
         on(shell_lex._subst_bodies, "cat <<E\n$\\\n(rm -rf src)\nE\n") == (["rm -rf src"], True)),
        # Deviation 1: over the cap, a quote-split `<<` blocks before any reading runs.
        ("an over-cap <\"\"< program blocks", cmdword.is_file_mod(R46 + "\necho " + "a" * 40000)),
        ("an over-cap command with no heredoc shape does not", not cmdword.is_file_mod("echo " + "a" * 40000 + "\necho b")),
    ]
    # The ${...} recursion keeps the body's _arith_closes cache: characters rebuilt on a
    # cache miss stay linear in the body (round 1's recursion rebuilt it once per ${...}).
    b, orig, cost = "$((1))${a-$((1))}" * 400, shell_lex._arith_closes, [0]

    def counting(s, i):
        if shell_lex._paren_matches[0] is not s:
            cost[0] += len(s)
        return orig(s, i)
    shell_lex._arith_closes = counting
    try:
        scanned = on(shell_lex._heredoc_substs, b, [])
    finally:
        shell_lex._arith_closes = orig
    checks.append(("${...} recursion keeps the body's arithmetic cache (%d chars rebuilt)" % cost[0],
                   scanned and cost[0] < 3 * len(b)))
    # The heredoc-free pass leaves _stdin_memo as the first pass left it: its hits are not
    # charged, so an entry only that pass made would let a later sibling skip a charge.
    t = "cat <<E\nit's\nE\necho a | foo x\necho 'y'"
    cmdword.is_file_mod("true")                  # a top-level call resets budgets and memos
    cmdword._stdin_memo.clear()
    on(cmdword._is_file_mod_text, t, 1)
    first = set(cmdword._stdin_memo)
    cmdword._stdin_memo.clear()
    on(cmdword._is_file_mod_text, cmdword._heredoc_frees(t)[0], 1)
    cut = set(cmdword._stdin_memo)
    cmdword._stdin_memo.clear()
    on(cmdword._is_file_mod, t, 1)
    checks.append(("the heredoc-free pass leaves _stdin_memo as it found it",
                   cut - first != set() and set(cmdword._stdin_memo) == first))
    for label, good in checks:
        fx.ok("switch: " + label) if good else fx.no("switch: " + label, "differs")


def rows(repo):
    switch_rows()
    for label, cmd in BLOCK:
        if not fx.writes(cmd):
            fx.no(label, "bash 5 did not write -- the row proves nothing")
            continue
        got, _dt = fx.hook(repo, cmd)
        fx.ok(label) if got == "block" else fx.no(label, "hook said " + got)
    for label, cmd in ALLOW:
        if fx.writes(cmd):
            fx.no(label, "a control that writes")
            continue
        got, _dt = fx.hook(repo, cmd)
        fx.ok(label) if got == "allow" else fx.no(label, "hook said " + got)
    for label, cmd in KNOWN_ALLOW:
        if not fx.writes(cmd):
            fx.no(label, "a known allow that does not write -- the row proves nothing")
            continue
        got, _dt = fx.hook(repo, cmd)
        fx.ok(label) if got == "allow" else fx.no(label, "now %s: flip this row" % got)
    for label, cmd in KNOWN_BLOCK:
        if fx.writes(cmd):
            fx.no(label, "a known over-block that writes")
            continue
        got, _dt = fx.hook(repo, cmd)
        fx.ok(label) if got == "block" else fx.no(label, "now %s: move this row to ALLOW" % got)
    # Three nested levels near the cap, read-only, allowed by main and here. Four is refused
    # by the gate-state helper scan before the design check runs, on main too.
    cmd = nest(3, 30000 - 120)
    got, dt = fx.hook(repo, cmd, timeout=10)
    label = "timing: %d chars of three nested heredoc programs allowed in %.2fs" % (len(cmd), dt)
    fx.ok(label) if got == "allow" and dt <= fx.LIMIT else fx.no(label, "over %.1f s or %s" % (fx.LIMIT, got))
    # ${...} holding $(( )), repeated through one body: the inner scan keeps the cache.
    unit = "$((1))${a-$((1))}"
    cmd = "cat <" + "<E\n" + unit * ((fx.CAP - 80) // len(unit)) + "\nE\nrm -rf src"
    got, dt = fx.hook(repo, cmd, timeout=10)
    label = "timing: %d chars of ${a-$((1))} in one body then a write blocked in %.2fs" % (len(cmd), dt)
    fx.ok(label) if got == "block" and dt <= fx.LIMIT else fx.no(label, "over %.1f s or %s" % (fx.LIMIT, got))
    # Body and top-level $(( )) alternating, under and over the cap, then a write.
    unit = ": $((1)) <" + "<E\n$((1))\nE\n"
    for size in (fx.CAP - 800, 64000):
        cmd = unit * (size // len(unit)) + "rm -rf src"
        got, dt = fx.hook(repo, cmd, timeout=10)
        label = "timing: %d chars of $(( )) bodies then a write blocked in %.2fs" % (len(cmd), dt)
        fx.ok(label) if got == "block" and dt <= fx.LIMIT else fx.no(label, "over %.1f s or %s" % (fx.LIMIT, got))


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "rows":
        print(__doc__)
        return 2
    fx.BASH = fx.bash5()
    rows(sys.argv[2])
    print("SUMMARY %d %d" % (fx.PASS, fx.FAIL))
    return 1 if fx.FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
