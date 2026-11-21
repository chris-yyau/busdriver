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
TWO = ": </dev/null </dev/null\n"
BARE = r"bash -c 'echo x \\\> src/f" + "\n" + r"echo \\\"'"
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
    # PR #1115 review: a redirect the raw text already shows must not hide one only the cut shows.
    ("R62 F8 with a raw redirect and a redirect only the cut shows",
     "cat <<E > out.log\ndon't\nE\nsh litmus/scripts/x\necho x > src/f\necho 'y'"),
    ("R63 R62 with the same redirect as a decoy in the body",
     "cat <<E > out.log\necho x > src/f\ndon't\nE\nsh litmus/scripts/x\necho x > src/f\necho 'y'"),
    # PR backstop: a continuation-split `<\<nl><` still gets the heredoc-free pass.
    ("R60 R1 with a split << and a $ in the body", "cat <\\\n<E\nit's $x\nE\nrm -rf src\necho 'y'"),
    ("R61 R60 with a redirect", "cat <\\\n<E\nit's $x\nE\necho x > src/f\necho 'y'"),
    # Round-6 regressions of the withdrawn unquoted-body join: a `<<` that is no heredoc.
    ("J1 $((1<<2)) before a quoted body", ": \"$(echo $((1<<2))\ncat <<'EE'\nE\\\nE\n)\nEE\nrm -rf src)\""),
    ("J2 # <<EOF before a quoted body", ": \"$(echo # <<EOF\ncat <<'EE'\nE\\\nE\n)\nEE\nrm -rf src)\""),
    ("J3 \"<<EOF \" at top level", "echo \"<<EOF \"\ncat <<'END'\nE\\\nND\nit's\nEND\nrm -rf src\ncat <<'E2'\ndon't\nE2"),
    ("O5 a double quote opened on the <<EOF line (#1113)",
     "true <<EOF \"hello\nEOF\nworld\"\necho it's\nE\\\nOF\necho x > src/f\necho 'y'"),
    # #1113: no heredoc body starts inside `${…}`.
    ("O6 a ${ opened on the <<E line (#1113)", "echo <<E ${v:-\nE\n}\nit's\nE\nrm -rf src\ncat <<E2\ndon't\nE2"),
    # A bare `((true)` after the operator is two subshells: the body still starts at its newline.
    ("O31 ((true) on the <<E line (#1113)", "cat <<E; ((true)\nit's\nE\n)\nrm -rf src\ncat <<E2\ndon't\nE2"),
    ("O12 R1 behind a UTF-8 byte delimiter (#1093 3)", "cat <<$'E\\xc3\\xa9'\nit's\nEé\necho x > src/f\necho 'y'"),
    ("O13 terminator split by a continuation (#1093)", "cat <<EOF\nit's\nE\\\nOF\necho x > src/f\necho 'y'"),
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
    ("O2 one-line program ending in a lone backslash (#1112)", "bash -c " + q("echo x > src/f; echo \\")),
    ("O7 bash -c program ending in an open quote (#1093 1b)", "bash -c " + q(UNREADABLE)),
    ("O8 bash -c redirect then an open quote (#1093 1b)", "bash -c " + q(P19)),
    ("O9 bash -c redirect then an open double quote (#1093 1b)", "bash -c " + q(DQ)),
    ("O10 O8 inside a double-quoted $( ) (#1093 1b)", ': "$(bash -c ' + q(P19) + ')"'),
    ("O11 find -exec O8 (#1093 1b)", FIND + q(P19) + " \\;"),
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
    # PR #1124 review: two inert < make the root heredoc-shaped, so the third reading runs.
    ("R118 two inert < redirects, then O9", "bash -c ': </dev/null </dev/null\necho x > src/f\necho \"'"),
    # PR #1124 review: env -S stops at \c, so the apostrophe is never read; K38 is its twin.
    ("R119 an env -S program ending in \\c and an apostrophe", "env -S \"sh -c 'echo x > src/f' \\c it's\""),
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
    ("C19 split $( in a body, read-only", "cat <<E\nit's $\\\n(date)\nE\necho 'y'"),
    ("C25 escaped $' in a body backtick is read unescaped", "cat <<E\n`echo \\$'it\\'s'`\nE"),
    ("C27 a review-script redirect is still exempt", "bash skills/litmus/scripts/none.sh > out.log"),
    ("C29 echo $'\\xff' (no heredoc)", "echo $'\\xff'"),
    ("C41 a quoted delimiter word holding a continuation, after an apostrophe body",
     "cat <<A\nit's\nA\ncat <<'E'\\\nOF\nhello\nE\\\nOF\nEOF\necho ok"),
    ("C42 an escaped \\0 then digits is not a high byte", "cat <<$'E\\0200'\nhi\nE\necho ok"),
    ("C44 a backslash-only line, then the delimiter itself", "cat <<EOF\nit's\n\\\nEOF\necho ok"),
    ("C28 two < readable program", "bash -c " + q(TWO + "echo ok")),
    ("C35 an anchored grep in bash -c ($\" respelling)", "bash -c 'grep \"x\\$\" src/impl.py'"),
    ("C37 a comment line, then a quoted backtick, in bash -c", "bash -c " + q("# check backticks\ngrep '`' src/impl.py")),
    ("C39 a function header in a one-line program", "bash -c 'echo \"a;\"foo()'"),
    ("C40 a function header after an escaped ;", "bash -c 'echo \\; \"a()\"'"),
    ("C43 a CR in a read-only program", "bash -c 'echo \"a\rb\"\necho ok'"),
    ("C47 read-only twin of O6 (#1113)", "echo <<E ${v:-\nE\n}\nit's\nE\necho ok\ncat <<E2\ndon't\nE2"),
    ("C48 read-only twin of O30 (#1113)", "cat <<E $((1 +\nE\n2))\nit's\nE\necho ok\ncat <<E2\ndon't\nE2"),
]
# Known allows: they write, and main allows them too. Fixing one fails its row: flip it to BLOCK.
KNOWN_ALLOW = [
    ("O1 comment apostrophe hides a redirect (#1101 item 3)", "# it's\necho x > src/f\necho 'y'"),
    ("O3 ((true); subshells hide every later heredoc (#1113)",
     "((true); cat <<E\necho it's\nE\nrm -rf src\ncat <<E2\ndon't\nE2\n)"),
    ("O4 $(( ( (1)) << 2 )) read as a heredoc (#1113)",
     "cat <<E\nit's\nE\necho $(( ( (1)) << 2 ))\necho x > src/f\necho 'y'"),
    ("O30 a $(( opened on the <<E line (#1113)", "cat <<E $((1 +\nE\n2))\nit's\nE\nrm -rf src\ncat <<E2\ndon't\nE2"),
    # #1093 members left to later parts.
    ("O18 an apostrophe body in $( ), then a write", ": $(cat <<EOF\nit's\nEOF\n)\necho x > src/f\necho 'y'"),
    ("O19 an apostrophe body in a backtick, then a write", ": " + BT + "cat <<EOF\nit's\nEOF\n" + BT + "\necho x > src/f\necho 'y'"),
    ("O20 an apostrophe body in <( ), then a write", "cat <(cat <<EOF\nit's\nEOF\n)\necho x > src/f\necho 'y'"),
    ("O24 a braced escape spelling a redirect, no heredoc", "bash -c $'echo x \\x{3e} src/f'"),
    # Review (detectors plan, round 2): a body bash ends EARLY, at a line the joined read takes
    # as content, then a quote the gate reads differently. Follow-up issue.
    ("O28 a body ended early by a split line, then a write in a program",
     "bash -c " + q("cat <<EOF\nit's\nx\\\nEOF\necho '\nEOF\necho x > src/f\ncat <<E2\n'\nE2")),
    ("O29 O28's shape at top level, with rm", "cat <<EOF\nit's\nx\\\nEOF\necho '\nEOF\nc=r; ${c}m -rf src\ncat <<E2\n'\nE2"),
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
    ("K16 a byte escape beside an unclosed heredoc", "cat <<$'E\\xff'\nhi\nE\necho ok"),
    ("K17 read-only twin of O12", "cat <<$'E\\xc3\\xa9'\nit's\nE\u00e9\necho 'y'"),
    ("K18 read-only twin of R79", "bash -c $'cat <<$\\'E\\xff\\'\\nit\\'s\\nE\\xff\\necho ok\\necho $\\'\\\\x27\\''"),
    ("K19 read-only twin of R88", "bash -c $'cat <<E\u00e9\\nit\\'s\\nE\\xc3'$'\\xa9\\necho ok\\necho \\'y\\''"),
    ("K23 a herestring beside a byte escape", "cat <<< hi; echo $'\\xff'"),
    ("K24 an arithmetic shift beside a byte escape", "echo $((1<<8)); echo $'\\xff'"),
    ("K25 a single-quoted \\<nl> glued into a byte escape", "echo $'ok'\necho '\\\\\nxff'\ncat <<EOF\nhi\nEOF\necho ok"),
    ("K26 two < on separate lines beside a byte escape", "cat < /dev/null\necho '<' $'\\xff'"),
    ("K27 read-only twin of O13 (Task 2's split terminator)", "cat <<EOF\nit's\nE\\\nOF\necho 'y'"),
    ("K33 read-only twin of R117", "cat <<$'\\x{45}OF'\nit's\nEOF\necho 'y'"),
    # The escape and the `$'` need not be one string: any `$'` beside a literal high escape (PR #1121 review).
    ("K34 a literal \\xff in a quoted body beside an unrelated $'", "echo $'ok'\ncat <<'EOF'\n\\xff\nEOF\necho ok"),
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
    ("K30 a multi-line case arm in a process substitution in bash -c", "bash -c 'cat <(case x in\na) echo hi;;\nesac)'"),
    ("K31 a later -c in a program's positionals", "bash -c 'echo \"$1\"' _ -c \"it's\""),
    ("K32 a respelled header nested two programs down", "sh -c \"bash -c 'echo \\; \\\"a(\"''\")\\\"'\""),
    # Review (part 2a, round 10): a heredoc inside a substitution is not a top-level heredoc,
    # so _lexed_heredoc does not see it and the as-written block fires; and a one-line program
    # bash rejects outright (K12's class).
    ("K35 an apostrophe heredoc in a process substitution in bash -c", "bash -c 'cat <(cat <<EOF\nit'\\''s\nEOF\n)'"),
    ("K36 an apostrophe heredoc in a command substitution in bash -c", "bash -c ': $(cat <<EOF\nit'\\''s\nEOF\n)'"),
    ("K37 a one-line program whose escaped ) leaves $( open", "bash -c 'echo $(echo x > src/f; echo \\)'"),
    # PR #1124 review: env -S ignores the rest after \c; read-only twin of R119 (K15's class).
    ("K38 an env -S string ending in \\c and an apostrophe", "env -S \"echo hello\\c it's\""),
    # Was an ALLOW row: past 32,768 characters the marker guard blocks unscanned (#1109).
    # The no-heredoc shape still skips the third reading: see the is_file_mod row below.
    ("C18 over-cap newline command, no heredoc (#1109 scan ceiling)", "echo " + "a" * 33000 + "\necho b"),
]


def nest(levels, fill):
    # Each level a heredoc and then a bash -c of the next; read-only throughout.
    prog = "cat <<E\nx\nE\necho " + "a" * fill + "\necho ok"
    for _ in range(levels):
        prog = "cat <<E\nx\nE\nbash -c " + q(prog)
    return prog


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


def detector_checks(shell_lex, cmdword, on):
    # #1093 part 2: the split-terminator flag is cmdword-only and changes no end.
    return [
        ("split terminator: same end (on)",
         (shell_lex._split_term.__setitem__(0, False),
          on(shell_lex._heredoc_terminator, "it's\nE\\\nOF\nx", 0, ("EOF", False), True))[1] == (len("it's\nE\\\nOF\nx"),) * 2),
        ("split terminator flagged (on)", shell_lex._split_term[0] is True),
        ("split terminator not flagged (off)", (shell_lex._split_term.__setitem__(0, False),
         shell_lex._heredoc_terminator("it's\nE\\\nOF\nx", 0, ("EOF", False), True), shell_lex._split_term[0])[2] is False),
        ("byte heredoc marked", cmdword._byte_marks("cat <<$'E\\xc3\\xa9'\nhi\nE\u00e9") == (True, True)),
        ("no heredoc, no shape mark", cmdword._byte_marks("echo $'\\xff'") == (True, False)),
        ("octal escape marked", cmdword._byte_marks("cat <<$'E\\703\\651'\nhi\nE\u00e9") == (True, True)),
        ("continuation-split $' marked", cmdword._byte_marks("cat <<$\\\n'E\\xc3\\xa9'\nhi\nE\u00e9") == (True, True)),
        ("\\0200 is not a high byte", cmdword._byte_marks("cat <<$'E\\0200'\nhi\nE")[0] is False),
        ("braced escape marked", cmdword._byte_marks("cat <<$'\\x{45}OF'\nhi\nEOF") == (True, True)),
        ("a split line ending in the delimiter itself is not flagged",
         (shell_lex._split_term.__setitem__(0, False),
          on(shell_lex._heredoc_terminator, "it's\n\\\nEOF\nx", 0, ("EOF", False), True), shell_lex._split_term[0])[2] is False),
    ]


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
        # #1113: a newline inside `${…}` starts no body in either mode -- bash reads it after the word.
        ("a quoted body after a ${ } is not read (off)",
         shell_lex._subst_bodies("cat <<'E' ${v:-\nE\n}\n$(echo h)\nE\n") == ([], True)),
        ("a $( ) later in the ${ } is read (off; main misses it)",
         shell_lex._subst_bodies("cat <<'E' ${v:-\n$(echo h)\nE\n}\nE\n") == (["echo h"], True)),
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
        # A verdict-memo hit must not re-charge a stage main reads free from _stdin_memo:
        # main allows this with ~1,300 tokens left (PR #1115 review). The hook blocks it
        # for another reason, so it is pinned here, on is_file_mod.
        ("60 identical $( ) pipelines spend the scan budget as on main",
         not cmdword.is_file_mod("echo " + " ".join(
             '"$(cat f | grep ' + " ".join("a%d" % i for i in range(40)) + ')"' for _ in range(60)))),
        # The heredoc-free pass spends what the first pass left instead of a fresh depth-0
        # budget (PR #1115 review): ~2 x 2,100 tokens runs it out and blocks, 2 x 1,500 fits.
        ("the heredoc-free pass spends the first pass's leftover budget",
         cmdword.is_file_mod("cat <<E\nx\nE\necho " + "a " * 2100 + "\necho 'y'")),
        ("a heredoc-free pass inside the leftover budget is not a block",
         not cmdword.is_file_mod("cat <<E\nx\nE\necho " + "a " * 1500 + "\necho 'y'")),
        # #1093 part 2a: only a header _FUNC_DEF_RE would strip excludes the base reading.
        ("a quoted () is not a header", not cmdword._func_header("echo \"()\"\necho x")),
        ("a header is a header", cmdword._func_header("f() { :; }")),
    ] + detector_checks(shell_lex, cmdword, on)
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
    # A verdict records the stages it read from _stdin_memo too, not only those it added:
    # the heredoc-free pass drops its entries, so a later hit must pay for them (PR #1115).
    p = "echo a | foo x"
    cmdword.is_file_mod("true")
    on(cmdword.is_file_mod, p, 1)
    seen = set(cmdword._stdin_memo)
    cmdword._verdict_memo.clear()                # _stdin_memo kept: every stage is now a hit
    on(cmdword.is_file_mod, p, 1)
    rec = [v for k, v in cmdword._verdict_memo.items() if k[0] == p]
    checks.append(("a cached verdict records the _stdin_memo hits it used",
                   seen != set() and bool(rec) and all(set(v[2]) == seen for v in rec)))
    for label, good in checks:
        fx.ok("switch: " + label) if good else fx.no("switch: " + label, "differs")


def grid_rows(repo):
    for label, cmd, want in grid():
        if not fx.writes(cmd):
            fx.no(label, "bash 5 did not write -- the cell proves nothing")
            continue
        got, _dt = fx.hook(repo, cmd)
        fx.ok(label) if got == want else fx.no(label, "hook said %s, pinned %s" % (got, want))


def timed(label, got, dt, want):
    fx.ok(label) if got == want and dt <= fx.LIMIT else fx.no(label, "over %.1f s or %s" % (fx.LIMIT, got))


def table_rows(repo, table, spec):
    writes, want, why_writes, why_got = spec
    for label, cmd in table:
        if fx.writes(cmd) != writes:
            fx.no(label, why_writes)
            continue
        got, _dt = fx.hook(repo, cmd)
        fx.ok(label) if got == want else fx.no(label, why_got % got)


def rows(repo):
    switch_rows()
    table_rows(repo, BLOCK, (True, "block", "bash 5 did not write -- the row proves nothing", "hook said %s"))
    grid_rows(repo)
    table_rows(repo, ALLOW, (False, "allow", "a control that writes", "hook said %s"))
    table_rows(repo, KNOWN_ALLOW, (True, "allow",
               "a known allow that does not write -- the row proves nothing", "now %s: flip this row"))
    table_rows(repo, KNOWN_BLOCK, (False, "block", "a known over-block that writes", "now %s: move this row to ALLOW"))
    # Three nested levels near the cap, read-only, allowed by main and here. Four is refused
    # by the gate-state helper scan before the design check runs, on main too.
    cmd = nest(3, 30000 - 120)
    got, dt = fx.hook(repo, cmd, timeout=10)
    label = "timing: %d chars of three nested heredoc programs allowed in %.2fs" % (len(cmd), dt)
    timed(label, got, dt, "allow")
    # ${...} holding $(( )), repeated through one body: the inner scan keeps the cache.
    unit = "$((1))${a-$((1))}"
    cmd = "cat <" + "<E\n" + unit * ((fx.CAP - 80) // len(unit)) + "\nE\nrm -rf src"
    got, dt = fx.hook(repo, cmd, timeout=10)
    label = "timing: %d chars of ${a-$((1))} in one body then a write blocked in %.2fs" % (len(cmd), dt)
    timed(label, got, dt, "block")
    # Body and top-level $(( )) alternating, under and over the cap, then a write.
    unit = ": $((1)) <" + "<E\n$((1))\nE\n"
    for size in (fx.CAP - 800, 64000):
        cmd = unit * (size // len(unit)) + "rm -rf src"
        got, dt = fx.hook(repo, cmd, timeout=10)
        label = "timing: %d chars of $(( )) bodies then a write blocked in %.2fs" % (len(cmd), dt)
        timed(label, got, dt, "block")
    # A body of nothing but continuation lines near the cap: the joined-line check is linear.
    cmd = "cat <" + "<EOF\nit's\n" + "\\\n" * ((fx.CAP - 60) // 2) + "EOF\necho x > src/f"
    got, dt = fx.hook(repo, cmd, timeout=10)
    label = "timing: %d chars of continuation lines in one body blocked in %.2fs" % (len(cmd), dt)
    timed(label, got, dt, "block")

    # Thousands of segments shlex cannot read, at depth 0 and inside a heredoc-carrying
    # program: the first give-up decides the command, so the rest are not walked (#1093 part 2).
    for name, cmd in (("depth-0", (BT + '"' + BT + " ; ") * 5000 + "echo x > src/f"),
                      ("program", "bash -c 'cat <<E\nx\nE\n" + (BT + '"' + BT + "\n") * 5000 + "echo x > src/f'")):
        got, dt = fx.hook(repo, cmd, timeout=10)
        label = "timing: %s, %d chars of unparseable segments blocked in %.2fs" % (name, len(cmd), dt)
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
