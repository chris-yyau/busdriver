#!/usr/bin/env bash
# test-careful-guard-truncate-context.sh
# The TRUNCATE rule must fire on SQL and on the coreutils command — not on the
# ENGLISH WORD.
#
# `careful-guard.sh` matched a bare `\btruncate\b` against the whole lowercased
# command, so the word warned as "SQL TRUNCATE" wherever it appeared: inside a
# grep pattern, inside a Python string literal, inside prose in an echo. Measured
# against ~/.claude/watch-hooks.log — 176 real Bash permission prompts over six
# days — 20 of them (11%) were this rule, and NONE of the 20 was SQL. Every one
# was this repo's own gate tests mentioning the word.
#
# Over-warning is the safe direction for a guard, so the fix is not to relax the
# rule but to make it PRECISE about what it claims to detect:
#   SQL      -> `TRUNCATE TABLE`, or `truncate` alongside a SQL client
#   coreutils-> `truncate` at command-word position (it erases a file in place)
#   word     -> silent
set -uo pipefail
# Resolved BEFORE the cd: `$0` is relative, so a `dirname "$0"` read
# afterwards points at the new cwd. Sourcing then silently found
# nothing, `check` was undefined, and the suite exited 0 with fail=0 -
# a false PASS in the files that exist to prevent one.
_HERE=$(cd "$(dirname "$0")" && pwd) || exit 1
cd "$_HERE/.." || exit 1

# shellcheck disable=SC2034  # read by the sourced harness below
GUARD="hooks/gate-scripts/careful-guard.sh"

pass=0 fail=0

# <command> -> ask|allow|ERROR. bypassPermissions: every check is live there, so
# nothing below is masked by the auto-mode stand-down.
# shellcheck source=tests/lib/careful-guard-harness.sh
# shellcheck disable=SC1091  # the source= path above needs `shellcheck -x`
. "$_HERE/lib/careful-guard-harness.sh" || exit 1

echo "--- the word, not the operation (must be silent) ---"
# The exact command from the log that made this a 11%-of-all-prompts false positive.
check "grep pattern containing the word" allow \
  "grep -nE 'rm |mv |truncate' script.sh"
check "hyphenated word in prose"         allow \
  'echo "=== install.sh truncate-before-write, the F2 precondition ==="'
check "word inside a python literal"     allow \
  'python3 -c "print('"'"'env-wrapped truncate of the audit log is blocked'"'"')"'
check "word as part of a longer ident"   allow \
  'grep -n "chunks_and_truncation" hooks/gate-scripts/lib/gitcmd_detect.py'

echo "--- a SQL client NAMED but not RUN (must be silent) ---"
# Matching the client name anywhere kept the very class of false prompt this
# file exists to remove; the name must occupy COMMAND position.
check "client name as an operand"        allow 'grep truncate psql.log'
check "client name in an echo"           allow 'echo truncate psql'
# ...but the client walk must see through the same shapes the truncate walk does.
check "client after a heredoc-string"    ask  "<<< 'TRUNCATE users;' psql"
check "client behind a wrapper option"   ask  "printf 'TRUNCATE users;' | sudo -u postgres psql"
check "client inside a case body"        ask  "case x in x) psql -c 'TRUNCATE users';; esac"
check "client inside a function body"    ask  "f(){ psql -c 'TRUNCATE users'; }; f"
# Bash does not require whitespace after a case pattern closes, so the body can
# begin in the SAME token.
check "case body without whitespace"     ask  "case x in x)psql -c 'TRUNCATE users';; esac"
check "case body, truncate, no space"    ask  'case x in x)truncate -s 0 audit.log;; esac'
# ...and a WRAPPER there hides the real command one token further along.
check "case body opens with a wrapper"   ask  'case x in x)sudo truncate -s 0 audit.log;; esac'
check "case body wrapper + client"       ask  'case x in x)sudo psql -c "TRUNCATE users";; esac'
# A brace group can also OPEN the command word, which the grouping strip eats.
check "brace group as the command"       ask  '{truncate,truncate} -s 0 audit.log'
check "brace group as the client"        ask  '{psql,psql} -c "TRUNCATE users"'
# Bash expands NESTED groups too, so one pass is not enough.
check "nested brace command word"        ask  'tr{un,{xx,yy}}cate -s 0 audit.log'
check "nested brace client name"         ask  'p{s,{xx,yy}}ql -c "TRUNCATE users"'
# ...and the wrapper scan must expand from the raw token as well.
check "wrapper + brace group"            ask  'sudo {truncate,truncate} -s 0 audit.log'
check "wrapper + brace client"           ask  'sudo {psql,psql} -c "TRUNCATE users"'
# An in-token case body may itself open with a shell PREFIX rather than the
# command: a negation, a redirection, an assignment.
check "case body opens with !"           ask  'case x in x)! truncate -s 0 audit.log;; esac'
check "case body opens with a redirect"  ask  'case x in x)>/dev/null psql -c "TRUNCATE users";; esac'
check "case body opens with assignment"  ask  'case x in x)FOO=bar psql -c "TRUNCATE users";; esac'
check "case body wrapper with an arg"    ask  'case x in x)sudo -u root truncate -s 0 audit.log;; esac'
# Splitting on whitespace before stripping quoting destroys an escaped-space
# brace group before it can expand.
check "brace group with escaped space"   ask  'psq{l,l\ } -c "TRUNCATE users"'
check "deeply nested brace group"        ask  'tr{{{{{un,xx},yy},zz},aa},bb}cate -s 0 audit.log'
# An expansion in the DIRECTORY part leaves a literal basename; cutting at the
# expansion before taking the basename threw that name away.
# shellcheck disable=SC2016
check "expansion in the directory part" ask  '$PWD/truncate -s 0 audit.log'
# shellcheck disable=SC2016
check "quoted expansion, literal base"  ask  '"$PWD"/truncate -s 0 audit.log'
# shellcheck disable=SC2016
check "substitution directory part"     ask  '$(pwd)/truncate -s 0 audit.log'
# ...and a redirection target full of slashes must not become the basename.
check "redirect target with slashes"    ask  'truncate>/tmp/x -s 0 audit.log'
# A QUOTED redirection character is data, so the case branch must be read
# before the redirection one - shlex has already cooked `">"` down to `>`.
check "quoted > as a case subject"      ask  'case ">" in ">") psql -c "TRUNCATE users";; esac'
check "quoted > case, truncate body"    ask  'case ">" in ">") truncate -s 0 audit.log;; esac'
# Pathname expansion happens after this scan, so a GLOB is a command word that
# reaches the real executable while spelling no name. fnmatch answers exactly,
# so a pattern that cannot produce the name still does not match.
check "glob command word"               ask  '/usr/bin/truncat? -s 0 audit.log'
check "glob client name"                ask  '/usr/bin/psq? -c "TRUNCATE users"'
check "glob that cannot reach a name"   allow 'ls *.log && echo truncate'
check "glob with a wildcard TAIL"       ask  'trunc* -s 0 audit.log'
# ACCEPTED OVER-WARN, pinned: `*` matches every name in every set, so a glob
# operand at command position warns — as does a case pattern whose chunk lost
# its `case` header to a newline, which arrives as exactly that shape. The
# density rule that removed these two bought a fail-open in exchange
# (`[t][r][u][n][c][a][t][e]` measures as zero literal characters), so the
# fail-CLOSED answer stands. Measured cost: 19 prompts in 26,454.
check "bare glob at command position"   ask  'echo hi | docs/*'
# shellcheck disable=SC2016  # `$f` is case-subject text, not an expansion here
check "case pattern split by newline"   ask  'case "$f" in
  docs/*|*.md|LICENSE) ;;
esac'
check "character class spells a name"   ask  '/usr/bin/[t][r][u][n][c][a][t][e] -s 0 audit.log'
check "character class spells a client" ask  '/usr/bin/[p][s][q][l] -c "TRUNCATE users"'
# fnmatch has no POSIX bracket classes and bash does; each matches exactly one
# character, so `?` is the faithful stand-in.
check "POSIX class in the command word" ask  '/usr/bin/truncat[[:alpha:]] -s 0 audit.log'
check "POSIX class in the client name"  ask  'psq[[:alpha:]] -c "TRUNCATE users"'
# A bracket expression may CONTAIN a class alongside ordinary characters. Only
# the pure spelling was read, so the composite one — the same glob, one
# character longer — walked past the check the pure one failed.
check "class beside a literal"          ask  '/usr/bin/trunca[[:alpha:]x]e -s 0 audit.log'
check "literal before the class"        ask  '/usr/bin/psq[x[:alpha:]] -c "TRUNCATE users"'
check "negated class in the word"       ask  '/usr/bin/truncat[![:digit:]] -s 0 audit.log'
# A class in an OPERAND still spells no command word.
check "class in an operand"             allow 'ls /usr/bin/[[:digit:]]*'
# The rest of the bash bracket grammar arrived one spelling per review round, so
# the rule inverted: EVERY bracket expression matches exactly one character and
# becomes `?`, and fnmatch never has to implement a grammar it does not have.
check "negation with a caret"           ask  'truncat[^x] -s 0 audit.log'
check "equivalence class"               ask  'truncat[[=e=]] -s 0 audit.log'
check "collating symbol"                ask  'truncat[[.e.]] -s 0 audit.log'
check "plain bracket set"               ask  'truncat[e] -s 0 audit.log'
# ACCEPTED OVER-WARN, the price of that inversion: a bracket that could NOT
# produce the name warns anyway, because reading which characters a bracket
# admits is the grammar this rule exists to stop implementing.
check "bracket that cannot match"       ask  'truncat[xyz] -s 0 audit.log'
# A bracket may contain an ESCAPED close. shlex eats the backslash before this
# scan sees it, so the token arrives as `truncat[e]]` — a name one character too
# long. A `]` left over after the bracket substitution can only be there because
# that provenance was lost, so it is dropped.
check "escaped close in a bracket"      ask  'truncat[e\]] -s 0 audit.log'
check "escaped close, client"           ask  '/usr/bin/psq[l\]] -c "TRUNCATE users"'
check "a stray bracket in an operand"   allow 'ls a]b'
# Bash negates with `^` as well as `!`, and either may be followed by a literal
# close — `[^]x]` is the set "not ] and not x", which admits every other letter.
check "caret negation, literal close"   ask  '/usr/bin/truncat[^]x] -s 0 audit.log'
# The DISPATCHER identity must read with the same rejoin the names get: an empty
# expansion left seg_head as `f`, and the `-exec` behind it was never a dispatch.
# shellcheck disable=SC2016
check "dispatcher split by expansion"   ask  'EMPTY=; f${EMPTY}ind /usr/bin -name truncate -exec {} -s 0 audit.log \;'
# A rebinder can bind a LAUNCHER rather than the protected name, running the
# command through a name this scan has never heard of.
check "rebound wrapper runs it"         ask  'hash -p /usr/bin/env e; e truncate -s 0 audit.log'
check "rebound dispatcher hides -exec"  ask  'hash -p /usr/bin/find f; f /usr/bin -name truncate -exec {} -s 0 x \;'
# ACCEPTED OVER-WARN, measured at 6 prompts in 35,918: a rebinder segment that
# merely NAMES a launcher warns too, because the binding and the later use are
# not linked by any symbol table this scan keeps.
check "ordinary alias stays silent"     allow 'alias ll=ls'
# ACCEPTED LIMIT, MEASURED and declined: a NON-SHELL interpreter that execs
# another program from inside its own runtime is not read as a payload carrier.
# Refusing every interpreter -c/-e payload unread is 2,139 of 35,918 replayed
# commands (6.0%) — more than TRIPLING this guard's 624 prompts — and
# enumerating interpreters and their exec spellings is the ladder this file
# declines everywhere else, in languages where the spellings are unbounded.
check "python payload that execs"       allow 'python3 -c "import os; os.execvp(\"truncate\", [\"truncate\",\"-s\",\"0\",\"f\"])"'
# ...but a SHELL payload is exactly what this tokeniser can read.
check "shell payload that runs it"      ask  'sh -c "truncate -s 0 audit.log"'
# A substitution may carry whitespace and nesting, and shlex splits the word
# there — so the halves of the name land in DIFFERENT tokens and no removal of
# expansions puts it back. An unreadable command word is refused, not decoded.
check "name torn by a substitution"     ask  'trun$(printf "")cate -s 0 audit.log'
check "torn by a nested substitution"   ask  'ps$( (true) )ql -c "TRUNCATE users"'
check "torn by a compound command"      ask  'r$(if true; then :; fi)m -rf /etc'
# A close that LANDS but leaves no literal suffix is torn too: the `)` inside
# `$(x=")"; :)` is DATA, shlex drops the quotes, and the depth walk stops there —
# ending the token on punctuation while the name continues in the next one.
check "quoted close ends the token"    ask  'trun$(x=")"; :)cate -s 0 audit.log'
check "ordinary suffix is not torn"    allow 'e`true`cho hello'
# A computed OPERATOR expands to a real one, so comparing raw tokens let a safe
# branch appear to constrain a selection it never touched.
# shellcheck disable=SC2016
check "computed find operator"         ask  'find /usr/bin -name echo -${EMPTY}o -type f -exec {} -s 0 audit.log \;'
# The structural vocabulary reads GLOBS at command position: `/usr/bin/en?`
# resolves to env, which then runs whatever it is handed.
check "glob-spelled wrapper"           ask  '/usr/bin/en? truncate -s 0 audit.log'
check "glob-spelled sudo"              ask  '/usr/bin/sud? truncate -s 0 audit.log'
# ...and the PLACEHOLDER walk reads them too: an exact reading did not know a
# glob-spelled wrapper held the slot in front of `{}`.
check "glob-spelled exec wrapper"      ask  'find /usr/bin -name truncate -exec /usr/bin/e?v {} -s 0 audit.log \;'
# An operator written AFTER an action cannot retroactively unconstrain it —
# scanning the whole argv made a settled predicate look unread.
check "operator after a settled action" allow 'find . -name echo -exec {} \; , -print'
# ...but a substitution that CLOSES in its own token tears no name, and an
# assignment holding one holds no command slot at all.
check "substitution as an operand"      allow 'echo $(date)'
check "substitution with an argument"   allow 'ls $(pwd) -la'
# ...and a token that BEGINS with the opener is a whole substitution standing in
# for a word, not a name torn by one. Requiring a literal prefix is what makes
# the rule affordable: firing here too measured 240 extra prompts in 26,454.
check "whole substitution as an arg"    allow 'bash x.sh "$(git rev-parse --show-toplevel)" | head -1'
# NESTED expansions vanish the same way, and the one-level bodies of EXPANSION
# matched neither — so the removal repeats until a pass changes nothing rather
# than a regex learning to balance its own delimiters.
check "nested substitution in a name"   ask  'r$($(true))m -rf /etc'
check "nested substitution, coreutils"  ask  'trun$($(true))cate -s 0 audit.log'
check "nested substitution, client"     ask  'p$(${x})sql -c "TRUNCATE users"'
# shellcheck disable=SC2016
check "nested braces in the keyword"    ask  'x= y=; psql -c "TRUN${x:-${y}}CATE users"'
check "nested default stays an operand" allow 'echo ${HOME:-${PWD:-/tmp}}'
# ...to a FIXPOINT, with no pass count. A fixed cap is a fail-open with a
# published price: nest one level past it and the name reassembles for bash but
# not for the scan. Nine levels is one more than the cap that used to be here.
check "expansion nested past any cap"   ask  'trun${A1:-${A2:-${A3:-${A4:-${A5:-${A6:-${A7:-${A8:-${A9:-}}}}}}}}}cate -s 0 f'
# ACCEPTED, MEASURED: removing to a fixpoint rescans the string once per level,
# so a pathological nest is quadratic. At 5,000 levels (30 KB) the 3s alarm
# fires at ~3.1s and the scan returns its CONSERVATIVE verdict — the timeout
# path, which warns. The hot path is unchanged at ~79ms/call. That is the
# designed behaviour and not a bypass, so it is pinned rather than optimised:
# the cheaper alternative is a pass cap, and a cap is a fail-OPEN with a
# published price (nest one deeper and the name reassembles unread).
adversarial_nest=$(python3 -c 'n=400; print("trun"+"${A:-"*n+"}"*n+"cate -s 0 f")')
check "pathological nest still warns"   ask  "$adversarial_nest"
# A GLOB in the query text spells the keyword only after pathname expansion —
# `TRUNCAT?` reaches it when a file named `TRUNCATE users` sits in the working
# directory — and a word-boundary search finds nothing. fnmatch answers it
# exactly, but only for a pattern carrying a LITERAL letter: a bare `*` matches
# every name there is, and `SELECT * FROM t` is the most ordinary query in the
# language. Measured at 12 extra prompts over 35,918 replayed commands.
check "glob inside the query"           ask  'psql -c TRUNCAT?\ users'
check "bracket inside the query"        ask  'psql -c TRUNCAT[E]\ users'
check "a bare star is not a keyword"    allow 'psql -c "SELECT * FROM users"'
# ACCEPTED RESIDUAL: a pattern spelled ENTIRELY in wildcards carries no literal
# letter, so it is not read — the same residual the density rule left on the
# command-word side, and for the same reason.
# ...but the same glob at command POSITION is still read.
check "glob in the client name"          ask  'psq? -c "TRUNCATE users"'
# The torn-word check reads DEPTH, not the first `)`: a nested substitution
# closes itself first, so the token looked closed while its word ran on.
check "torn by a nested opener"         ask  'trun$(true$(true) )cate -s 0 audit.log'
# find evaluates left to right and STOPS at the first false term, so a `-name`
# written AFTER the action never ran when the placeholder did — reading it as a
# constraint let a predicate that never executed vouch for the one that did.
check "predicate after the action"      ask  'find /usr/bin/truncate -exec {} -s 0 audit.log \; -name never'
check "predicate before the action"     allow 'find . -name "*.log" -exec {} \;'
# A `-name` inside an earlier ACTION argv is an argument to the command being
# run, not a predicate constraining the search — and a dispatcher owns its whole
# argv, so the second action must still see the `find` in front of it even
# though the first action already took the most recent command word.
check "name inside an earlier action"   ask  'find /usr/bin -exec echo -name \; -exec {} -s 0 audit.log \;'
check "second action, client"           ask  'find /usr/bin -exec echo x \; -exec {} -c "TRUNCATE users" \;'
check "one action, readable predicate"  allow 'find . -type f -exec grep -l x {} \;'
# Truncating at the FIRST action reads only the branch that does NOT run: the
# predicate governing a later `-exec` sits past it, behind the `-o`.
check "predicate behind an -o branch"   ask  'find /usr/bin -name never -exec echo {} \; -o -name truncate -exec {} -s 0 audit.log \;'
check "-o branch, client"               ask  'find /usr/bin -name never -exec echo {} \; -o -name psql -exec {} -c "TRUNCATE users" \;'
# A WRAPPER does not hide the dispatcher: scanning the wrapper tail token by
# token lost find semantics entirely and the placeholder read as an operand.
check "wrapper in front of find"        ask  'env find /usr/bin -type f -exec {} -s 0 audit.log \;'
check "wrapper, readable predicate"     allow 'env find . -name "*.log" -exec chmod 644 {} \;'
# split_segments cuts a case at its `|`, so a later alternative arrives as its
# own segment with the pattern still glued to the body. `y)truncate` is a word
# in no set at all while the command it runs is truncate; an UNMATCHED `)` is
# the only shape that carries this, since a substitution or group balances.
check "alternative glued to its body"   ask  'case y in x|y)truncate -s 0 f;; esac'
check "glued alternative, client"       ask  'case y in x|y)psql -c "TRUNCATE users";; esac'
check "balanced paren is not a close"   allow 'echo $(printf x)y'
# find drops a backslash before an ordinary character, so this predicate DOES
# select truncate — and a readable predicate that cannot match is exactly what
# says the selection is safe.
check "find pattern with an escape"     ask  "find /usr/bin -name 'truncat\\e' -exec {} -s 0 f \\;"
# A binding path can carry a brace group, which completes the name only after
# it expands — neither the raw nor the expansion-stripped text spells it.
check "rebind through a brace range"    ask  'hash -p /usr/bin/trunc{a..a}te zap; zap -s 0 f'
check "rebind through a brace list"     ask  'hash -p /usr/bin/trunc{a,b}te zap; zap -s 0 f'
# The structural vocabulary reads with the SAME rejoin the destructive names get.
# Comparing wrappers against one reading only was itself a bypass: the walk did
# not see a wrapper, so it never looked past it for the name it hides.
# shellcheck disable=SC2016
check "wrapper split by an expansion"   ask  'EMPTY=; e${EMPTY}nv truncate -s 0 audit.log'
# shellcheck disable=SC2016
check "wrapper split, client"           ask  'EMPTY=; e${EMPTY}nv psql -c "TRUNCATE users"'
# shellcheck disable=SC2016
check "wrapper split, benign payload"   allow 'EMPTY=; e${EMPTY}nv git status'
# shlex erases quote provenance, so a quoted `>` used as DATA reads as the
# operator — and its "operand" used to eat the `-exec` behind it, hiding the
# command find then ran. A redirection target is never a dispatch flag.
check "quoted > before -exec"           ask  "find . -name '>' -exec psql -c 'TRUNCATE users' ';'"
check "quoted > before -exec, coreutils" ask "find . -name '>' -exec truncate -s 0 audit.log ';'"
check "a real redirect still skips"     allow 'echo hi > /dev/null'
# shellcheck disable=SC2016
check "assignment torn the same way"    allow 'T=$(mktemp -d); echo "$T"'
# A wrapper option can carry an executable value, but a bare NAME=word is DATA:
# reading every assignment value as a command made each mention of a name warn.
check "env assignment is data"          allow 'env NOTE=truncate echo ok'
check "env assignment naming a client"  allow 'env NOTE=psql echo ok'
check "option value that IS a command"  ask   'ssh h -o ProxyCommand="truncate -s 0 audit.log"'
# Deleting the quoting is what lets `TR"UNC"ATE` rejoin, and it is also what
# GLUES an attached short option to the keyword: `-c'TRUNCATE ...'` collapses to
# `-ctruncate`, where the word boundary the search needs no longer exists. Both
# readings are searched, because each answers a half the other cannot.
check "attached -c before the keyword"  ask   "psql -c'TRUNCATE users'"
check "attached -e before the keyword"  ask   "mysql -e'TRUNCATE TABLE users'"
check "attached -q, unlisted client"    ask   "clickhouse-client -q'TRUNCATE TABLE users'"
# ...and the rejoin the deletion exists for must survive the second reading.
check "quote-split keyword still reads" ask   'psql -c "TR"UNC"ATE users"'
# A wrapper OPTION can carry an executable VALUE, which reads as an assignment.
check "ssh ProxyCommand truncate"       ask  "ssh -o 'ProxyCommand=truncate -s 0 audit.log' host"
# Bash dollar-quoting. shlex implements neither form, so the bare dollar was
# left behind and the command-word normaliser cut the word there — and merely
# DROPPING it is half the job, because the escape form also decodes.
check "ANSI-C escape in the name"       ask  "\$'trunc\\x61te' -s 0 audit.log"
check "ANSI-C escape in the client"     ask  "\$'p\\x73ql' -c 'TRUNCATE users'"
check "ANSI-C in the keyword"           ask  "psql -c \$'TRUNC\\x41TE users'"
check "ANSI-C that spells nothing"      allow "printf '%s' \$'a\\tb'"
# The escape grammar is BASH's, not Python's. Python demands four digits after
# a short unicode escape and RAISES on the bash-legal form, and the handler
# then left the word undecoded and the command allowed.
check "short unicode escape"            ask  "\$'\\u74runcate' -s 0 audit.log"
check "short unicode, client"           ask  "\$'p\\u73ql' -c 'TRUNCATE users'"
check "octal escape in the name"        ask  "\$'trunc\\141te' -s 0 audit.log"
check "long unicode escape"             ask  "\$'\\U00000074runcate' -s 0 audit.log"
check "an escape sequence in prose"     allow "echo \$'\\e[31mred'"
# A control escape whose character has a MULTI-character uppercase form used to
# raise inside ord() and kill the scanner outright; the bash arm then read the
# missing verdict as "no python3" and fell back to grepping raw text, which the
# quoted spelling walks straight past. Both halves are pinned: the escape itself
# stays quiet, and the payload beside it is still seen.
check "control escape, prose only"      allow "printf %s \$'\\cß'"
check "control escape beside a name"    ask   "printf %s \$'\\cß'; tr\"unc\"ate -s 0 audit.log"
check "control escape, ASCII"           allow "printf %s \$'\\cA'"
# Bash ENDS a dollar-quoted value at a decoded NUL, so the text after it is gone
# and the halves either side of an empty one meet. Keeping the byte spelled a
# name in no set at all, and every numeric form of the escape reached it.
check "NUL escape in the name"          ask   "trunc\$'\\0'ate -s 0 audit.log"
check "NUL escape in the client"        ask   "p\$'\\x00'sql -c 'TRUNCATE users'"
check "NUL control escape"              ask   "trunc\$'\\c@'ate -s 0 audit.log"
# The value is CUT at the NUL, not merely stripped of it: what bash runs here is
# `truncate`, so a suffix hiding behind one buys nothing.
check "NUL cuts the trailing junk"      ask   "\$'truncate\\0junk' -s 0 audit.log"
check "NUL cuts junk, client"           ask   "\$'psql\\0junk' -c 'TRUNCATE users'"
# ...and the cut is real in the other direction too: bash passes `TRUNC` to psql,
# which names no operation, so a warning here would be a false one.
check "NUL cuts the keyword short"      allow "psql -c \$'TRUNC\\u0000ATE users'"
# The case delimiter is the first paren OUTSIDE a substitution. Splitting at the
# LAST one discarded a body carrying its own parens.
# shellcheck disable=SC2016
check "substitution in the case body"   ask  'case x in x)psql$(true) -c "TRUNCATE users";; esac'
# shellcheck disable=SC2016
check "substitution in body, truncate"  ask  'case x in x)truncate$(true) -s 0 audit.log;; esac'
# The client-INDEPENDENT phrase must read the same normalised way the
# client-gated one does, or an UNLISTED client sees straight past it.
check "TABLE phrase, unlisted client"   ask  'isql mydsn<<<TR"UNC"ATE\ TABLE\ users'
check "TABLE phrase through a brace"    ask  'somecli -e TRUN{C,C}ATE\ TABLE\ orders'
check "the common IFS idiom"            allow "IFS=\$'\\n'; echo hi"
# An interpreter run by NAME carries its script in an operand. The top-level
# chunk splitter lifts that payload out on its own; a NESTED one never reaches
# it, so `sh` simply consumed the command slot.
check "nested sh -c payload"            ask  'find . -exec sh -c "psql -c \"TRUNCATE users\"" \;'
check "nested sh -c, coreutils"         ask  'find . -exec sh -c "truncate -s 0 audit.log" \;'
check "sh -c payload that is data"      allow 'sh -c "echo psql"'
check "an interpreter running a file"   allow 'bash tests/test-careful-guard-truncation.sh'
# `trap HANDLER SIGNAL` is the same shape wearing a builtin name: the handler
# is a command string that runs later, not data.
check "trap handler, client"            ask  'trap "psql -c \"TRUNCATE users\"" EXIT'
check "trap handler, coreutils"         ask  'trap "truncate -s 0 audit.log" EXIT'
check "trap handler that is data"       allow 'trap "echo done" EXIT'
check "ssh ProxyCommand client"         ask  "ssh -o 'ProxyCommand=psql -c \"TRUNCATE users\"' host"
# `find -exec {}` runs the file it FOUND, so the -name pattern is what says
# which executable runs.
check "find -exec placeholder"          ask  'find /usr/bin -name truncate -exec {} -s 0 audit.log \;'
check "find -exec placeholder, client"  ask  "find /usr/bin -name psql -exec {} -c 'TRUNCATE users' \;"
check "find -delete is not a dispatch"  allow 'find . -name "*.tmp" -delete'
# When nothing READABLE constrains the selection, the file the placeholder runs
# is unconstrained — so it may be any of them. Refusing the unreadable, rather
# than enumerating predicate spellings, is what closes -regex and its siblings
# in one rule.
# The placeholder holds the COMMAND slot even with a wrapper in front of it, so
# the slot is walked rather than peeked at a fixed offset.
check "wrapper before the placeholder" ask  'find /usr/bin -name truncate -exec env FOO=1 {} -s 0 audit.log \;'
check "sudo before the placeholder"    ask  'find /usr/bin -name psql -exec sudo {} -c "TRUNCATE users" \;'
# A wrapper OPTION takes an operand, and that operand is a bare word no scan can
# tell from a command word — so `-u root` used to end the walk one token short of
# the placeholder. Past a wrapper the walk refuses rather than reads: any `{}`
# still standing before `;` or `+` holds the slot.
check "wrapper option operand"         ask  'find /usr/bin -name truncate -exec sudo -u root {} -s 0 audit.log \;'
check "wrapper option operand, client" ask  'find /usr/bin -name psql -exec sudo -u root {} -c "TRUNCATE users" \;'
# ...but with no wrapper in front, a bare word still takes the slot.
check "bare word takes the slot"       allow 'find /usr/bin -name truncate -exec chmod 644 {} \;'
# Bash deletes a backslash-newline before it tokenises anything, so the two
# halves are ONE word — every scanner here used to see neither name.
check "line continuation in the name"  ask  '/usr/bin/trun\
cate -s 0 audit.log'
check "line continuation in keyword"   ask  'psql -c "TRUN\
CATE users"'
check "line continuation, no name"     allow 'echo one \
two'
check "find -regex selects the name"    ask  'find /usr/bin -regex ".*/truncate" -exec {} -s 0 audit.log \;'
check "find -regex, client"             ask  'find /usr/bin -regex ".*/psql" -exec {} -c "TRUNCATE users" \;'
check "find -regex beside a -name"      ask  'find /usr/bin -name "*.log" -o -regex ".*/x" -exec {} -s 0 f \;'
check "find with no name predicate"     ask  'find /usr/bin -type f -exec {} -s 0 audit.log \;'
# The comma joins two INDEPENDENT expressions, so a readable -name on the left
# constrains nothing on the right. It belongs with the other operators.
check "find comma operator"             ask  'find /usr/bin -name "*.log" , -type f -exec {} -s 0 audit.log \;'
# A COMPUTED pattern reads as nothing and so constrains nothing — counting it as
# readable let a predicate that says nothing stand in for one that says safe.
check "computed -name pattern"          ask  'C=truncate; find /usr/bin -name "$C" -exec {} -s 0 audit.log \;'
check "computed -name, client"          ask  'C=psql; find /usr/bin -name "$C" -exec {} -c "TRUNCATE users" \;'
# find substitutes `{}` ANYWHERE in an argument, so an exact-token match read a
# placeholder carrying a path prefix as an ordinary operand.
check "placeholder inside an argument"  ask  'find /usr/bin -name truncate -execdir ./{} -s 0 audit.log \;'
check "readable -name that misses"      allow 'find . -name "*.log" -exec {} \;'
# The placeholder is only a COMMAND word when it comes first; past that it is an
# ordinary operand and the real command word has already been read.
check "placeholder as an operand"       allow 'find . -type f -exec chmod 644 {} \;'
# A rebind hides the coreutils name exactly as it hides a client name.
check "hash -p rebound truncate"        ask  'hash -p /usr/bin/truncate zap; zap -s 0 audit.log'
check "alias-rebound truncate"          ask  'alias zap=truncate; zap -s 0 audit.log'
check "unrelated rebind, word nearby"   allow 'alias ll=ls; echo truncate'
# Previously an accepted limit on the grounds that a second EXPANDER for
# extglob would be the spelling ladder. Refusing it is not that: the operator
# set is the documented five, fnmatch has no such syntax, and an unreadable
# pattern at command position is what this file refuses everywhere else.
# `bash -O extglob -c ...` enables it without any shopt in the command.
check "extglob command word"            ask  '/usr/bin/@(truncat?|nope) -s 0 audit.log'
check "extglob, client name"            ask  '/usr/bin/@(psq?|nope) -c "TRUNCATE users"'
check "extglob behind -O"               ask  "bash -O extglob -c '/usr/bin/@(truncat?|nope) -s 0 audit.log'"
# ...but a bare paren is not an extglob operator.
check "plain paren in an operand"       allow 'echo (x)'
# A QUOTED close inside an expansion is gone by the time this scan runs, so the
# depth walk shuts at the first delimiter and orphans the rest of the name.
# Removing to the LAST close is the opposite reading; it matches only when the
# fragments either side spell the name themselves.
check "quoted close in a paren subst"   ask  'unset x; trun$(x=")")cate -s 0 f'
check "quoted close in a brace subst"   ask  'unset x; trun${x+"}"}cate -s 0 f'
check "quoted close, client"            ask  'unset x; p${x+"}"}sql -c "TRUNCATE users"'
# COMPOSED, too: a single first-to-last reading only ever handled one expansion,
# so the run of closers each quoted close leaves behind is consumed instead.
check "two quoted closes in a name"     ask  'trun$(x=")")ca$(x=")")te -s 0 audit.log'
check "quoted close in the keyword"     ask  'psql -c "TRUN$(x=")")CATE users"'
# An ASSIGNMENT is data even inside a wrapper tail. _cmd_word takes a BASENAME,
# so a value holding a path read as the command itself.
check "wrapper tail assignment, path"   allow 'env TOOL=/usr/bin/truncate echo ok'
check "wrapper tail assignment, client" allow 'env TOOL=/usr/bin/psql echo ok'
# ...but the wrapper still hides a real command word behind its options.
check "wrapper with a real command"     ask  'env truncate -s 0 audit.log'
# ANSI-C quoting is NOT active inside double quotes — bash prints the dollar and
# the quotes literally — so decoding there invented a command name the shell
# never runs. The quotes still stand in the RAW text the fold reads, which is the
# one place that state survives.
check "ANSI-C inside double quotes"     allow '"tr$'"'"'uncate'"'"'" -s 0 audit.log'
# ...and a double quote inside SINGLE quotes opens nothing, so it must not
# switch the decoding off for the rest of the command.
check "double quote inside singles"     ask   'X='"'"'"'"'"' $'"'"'truncate'"'"' -s 0 audit.log'
check "ANSI-C outside quotes decodes"   ask   "\$'trunc\\x61te' -s 0 audit.log"
# An EXEC-VALUED option needs no payload: its value IS the command word. The
# generic NAME=value rule requires one, so this read as ordinary data.
check "container entrypoint option"     ask  'docker run --entrypoint=truncate alpine -s 0 /data/f'
check "entrypoint naming a client"      ask  'docker run --entrypoint=psql img -c "TRUNCATE users"'
check "entrypoint naming a shell"       allow 'docker run --entrypoint=sh alpine -c "echo hi"'
# An unterminated bracket used to backtrack exponentially and spend the whole
# scan budget, leaving no verdict at all — which the bash arm reads as
# "no python3" and answers with raw grep.
#
# The fixture command itself is GENERATED, and unchecked: if this python3 call
# failed, the substitution is empty and `check` would run "allow" against an
# EMPTY command, which the guard's no-command branch clears unconditionally —
# a vacuous pass that never exercises the bracket path it names.
bracket_fixture=$(python3 -c 'print("[" + "\\\\a"*25 + " -s 0 f")')
if [[ -z "$bracket_fixture" ]]; then
  echo "FAIL could not build the unterminated-bracket fixture"
  fail=$((fail+1))
else
  check "unterminated bracket is fast"  allow "$bracket_fixture"
fi
# ACCEPTED LIMIT, pinned and OUT OF SCOPE: a script fed to an interpreter over
# stdin is not among the extracted chunks. That is gitcmd_detect chunk
# extraction — issue #557, being fixed in its own worktree.
check "script fed to bash over stdin"   allow "printf '%s' 'truncate -s 0 f' | bash"
# A QUOTED heredoc body is dropped as inert shell data, but it is exactly where
# a SQL statement lives when it is fed to a client.
check "quoted heredoc SQL body"         ask  "$(printf 'psql <<%sSQL%s\nTRUNCATE users;\nSQL' "'" "'")"
# A wrapper argument can CARRY the client rather than BE it: after shlex the
# whole payload is one token, so an exact-token match reads it as an operand.
check "client in a watch payload"        ask  "watch \"psql -c 'TRUNCATE users'\""
check "client in a script payload"       ask  "script -c \"psql -c 'TRUNCATE users'\""
check "client in a parallel payload"     ask  "parallel \"psql -c 'TRUNCATE users'\""
# An UNREADABLE command word hides the client. Going semantic must not lose what
# the raw-text rule caught, so a command that names a client somewhere AND runs
# an unresolvable command word fails CLOSED.
# shellcheck disable=SC2016
check "client held in a variable"        ask  'C=psql; "$C" -c "TRUNCATE users"'
# shellcheck disable=SC2016
check "client from a substitution"       ask  '$(printf psql) -c "TRUNCATE users"'
# shellcheck disable=SC2016
check "client from a backtick"           ask  '`printf psql` -c "TRUNCATE users"'
# ...and the mode must survive the wrapper recursion into a quoted payload.
# shellcheck disable=SC2016
check "unreadable client in a payload"   ask  'watch '"'"'C=psql; "$C" -c "TRUNCATE users"'"'"''
# A separated `>&` takes the NEXT token as its operand; without that the operand
# consumed the command slot and the real command word read as an argument.
check "client after separated >&"        ask  '>& out.log psql -c "TRUNCATE users"'
check "client after separated 2>&"       ask  '2>& 1 psql -c "TRUNCATE users"'
# The DANGLING operator is what carries the operand, never the character that
# split there: `>|` splits on the pipe and orphans the very same target.
check "client after a clobber >|"        ask  '>| /dev/null psql -c "TRUNCATE users"'
check "coreutils after a clobber >|"     ask  '>| /dev/null truncate -s 0 audit.log'
check "clobber before a benign command"  allow '>| /dev/null echo hi'
# ...but an ESCAPED redirection character is a literal argument, not an
# operator, so it must not swallow the next segment command word.
check "escaped > is not a redirect"      ask  'echo \> & psql -c "TRUNCATE users"'
check "escaped > before truncate"        ask  'echo \> & truncate -s 0 audit.log'
# coproc takes an OPTIONAL name before the command it runs.
check "coproc with a name"               ask  'coproc worker psql -c "TRUNCATE users"'
check "coproc without a name"            ask  'coproc psql -c "TRUNCATE users"'
# An expansion supplies the word separators, so a payload can carry a whole
# command with no literal whitespace in it at all.
# shellcheck disable=SC2016
check "IFS-separated truncate"           ask  'truncate${IFS}-s${IFS}0${IFS}audit.log'
# shellcheck disable=SC2016
check "IFS-separated wrapper payload"    ask  'watch '"'"'psql${IFS}-c${IFS}"TRUNCATE${IFS}users"'"'"''
# An operator separates a payload just as well as a space does.
check "operator-separated payload"       ask  "watch 'true;psql<<<TRUNCATE/**/users'"
# `builtin` dispatches like the other wrappers.
check "builtin exec dispatch"            ask  'builtin exec psql -c "TRUNCATE users"'
check "builtin command dispatch"         ask  'builtin command psql -c "TRUNCATE users"'
# ACCEPTED OVER-WARN, pinned so the trade stays visible: the client scan answers
# "does a client RUN here", not "does THAT client run the truncate". Attributing
# the word to one invocation means modelling which argument of which command it
# is, and the pipeline shape above puts them in different segments on purpose.
check "benign query beside the word"     ask  'psql -c "SELECT 1"; echo truncate'
# A rebind only counts when it RUNS and its own segment names a client.
check "rebinder word as data"            allow 'echo alias psql truncate'
check "unrelated rebind"                 allow 'alias ll=ls; echo psql truncate'
# Quoting cannot hide the SQL KEYWORD either: the scanner reads it the way bash
# does, so a raw grep for the word is only the scanner-absent fallback.
check "quote-concatenated TRUNCATE"      ask  'psql -c TR"UNC"ATE\ users'
# Bash expands braces long after this scan, so the command word is one token
# here; the alternatives are expanded rather than matched as text.
check "brace-expanded command word"      ask  'trun{ca,ca}te -s 0 audit.log'
check "brace-expanded client name"       ask  'psq{l,l} -c "TRUNCATE users"'
check "brace SEQUENCE in the keyword"    ask  'psql -c TRUN{C..C}ATE\ users'
# An escaped space keeps a word whole, but stripping the quoting characters
# leaves a bare space behind — which tore the brace group into pieces no
# expansion could rejoin. It is folded to a non-splitting character first now.
check "escaped space inside the braces"  ask  'psql -c TRUN{C,C\ }ATE\ users'
check "escaped space, no keyword"        allow 'psql -f trun\ cate.sql'
check "wrapper + brace command word"     ask  'sudo trun{ca,ca}te -s 0 audit.log'
# ACCEPTED OVER-WARN, pinned: shlex drops quote provenance before the brace
# expansion runs, so a QUOTED brace - which bash leaves literal - expands here
# too. Quote provenance is the one thing this scanner cannot recover; the
# replay measured this at zero cost.
check "quoted braces over-warn"          ask  '"trun{ca,ca}te" -s 0 audit.log'
# ACCEPTED LIMIT, pinned: removing an expansion assumes it yields NOTHING, so a
# keyword split by a NON-empty one still reads as `trunate`. Resolving the value
# is the ladder deleted twice; the raw-grep rule this replaced missed it too.
# shellcheck disable=SC2016
check "keyword split by a value"         allow 'C=C; psql -c "TRUN${C}ATE users"'
# ACCEPTED OVER-WARN, pinned: backslashes are stripped without quote state (it
# is gone by then), so an escape that bash would leave LITERAL still reads as
# the keyword. The opposite choice loses the real `TR\UNC\ATE` spelling.
check "backslash inside single quotes"   ask  "psql -c 'TRUN\\CATE users'"
# An expansion can SPLIT the keyword instead of hiding it: it rejoins once the
# expansion resolves to nothing.
# shellcheck disable=SC2016
check "expansion-split TRUNCATE"         ask  'EMPTY=; psql -c "TRUN${EMPTY}CATE users"'
# ...but an expansion that names no operation at all must stay silent.
# shellcheck disable=SC2016
check "client with an opaque query"      allow 'psql -c "$QUERY"'
# An expansion that expands to NOTHING lets the literal fragments either side
# rejoin, and the command word is then readable after all - the same reading the
# SQL keyword above already gets. Distinct from the accepted limit below: this
# matches only because the literals themselves spell the name.
# shellcheck disable=SC2016
check "expansion-prefixed command word"  ask   '${EMPTY}truncate -s 0 audit.log'
# shellcheck disable=SC2016
check "expansion-split command word"     ask   'tr${EMPTY}uncate -s 0 audit.log'
# ACCEPTED LIMIT, measured: an unreadable command word - one whose expansion
# carries the NAME rather than nothing - is still NOT failed closed on the
# truncate side. That rule was built and cost 23 extra prompts over 368 replayed
# commands - 6 of the 61 points - because a command running "$GUARD" that
# mentions truncate anywhere is this test loop. Same call as the variable and
# nameref limits.
# shellcheck disable=SC2016
check "valued command-word expansion"    allow 'T=truncate; $T -s 0 audit.log'
# An expansion is a SEPARATOR as often as it is empty, so reading the rejoined
# form must not cost the split one.
# shellcheck disable=SC2016
check "IFS-split client stays readable"  allow 'psql${IFS}-c${IFS}"SELECT 1"'
# A separating expansion can also LEAD. Reading field ZERO there yields the
# empty string, which is in no set; the command word is the first NON-EMPTY one.
# shellcheck disable=SC2016
check "leading separator expansion"      ask   '${IFS}truncate${IFS}-s${IFS}0${IFS}audit.log'
# shellcheck disable=SC2016
check "leading separator, client"        ask   '${IFS}psql${IFS}-c${IFS}"TRUNCATE users"'
# ...and reading past the empty field must not read past a REAL command word.
# shellcheck disable=SC2016
check "separator after a real name"      allow 'echo${IFS}truncate'
# Split on the expansions FIRST, basename SECOND. Basenaming the whole token
# read the last path component of the last FIELD — `${IFS}rm${IFS}-rf${IFS}/etc`
# basenamed to `etc`, a word in no set, while bash field-splits it into an argv.
# shellcheck disable=SC2016
check "whole argv inside one token"      ask  '${IFS}truncate${IFS}-s${IFS}0${IFS}/tmp/audit.log'
# shellcheck disable=SC2016
check "absolute name behind a separator" ask  '${IFS}/usr/bin/truncate${IFS}-s${IFS}0${IFS}/tmp/f'
# shellcheck disable=SC2016
check "separated client stays readable"  allow 'psql${IFS}-c${IFS}"SELECT 1"'
# NESTED expansions separate fields too. The one-level regex split neither
# `${x:-${IFS}}` nor `$($(printf " "))`, and a nested default is an ordinary
# way to spell a separator — so the whole argv hid inside one token.
# shellcheck disable=SC2016
check "nested separator expansion"       ask  '${x:-${IFS}}truncate${x:-${IFS}}-s${x:-${IFS}}0${x:-${IFS}}/tmp/x'

# An expansion in an OPTION is stripped to decide option-vs-operand, which is
# sound only when it VANISHES. It can equally SUPPLY the letter, and the two are
# indistinguishable without expanding, so the unreadable spelling is refused.
# shellcheck disable=SC2016
check "expansion supplies the r"         ask  'R=r; rm -${R}f /important/data'
# The same defect in the long form: `--${R}ecursive` strips to `--ecursive`,
# which fails the unambiguous-prefix test and read as an unknown long option.
# shellcheck disable=SC2016
check "expansion supplies long r"        ask  'R=r; rm --${R}ecursive /important/data'
# The VANISHING case is why stripping exists and must keep working.
# shellcheck disable=SC2016
check "expansion vanishes, flag stays"   ask  'rm $(true)-rf /etc'
# ...including when the expansion supplies the WHOLE short cluster, so the
# stripped token is a bare `-`. A length floor here let this one through.
# shellcheck disable=SC2016
check "expansion is the whole cluster"   ask  'R=r; rm -${R} /important/data'
# Refusing the unreadable must not swallow the non-recursive case outright: a
# plain `-f` with no expansion in it still clears.
check "plain -f stays non-recursive"     allow 'rm -f /important/data'
# shellcheck disable=SC2016
check "nested separator, benign"         allow '${x:-${IFS}}echo${x:-${IFS}}hello'
# The SPECIAL parameters are expansions too, and the most reliably empty ones
# bash has: a hook command runs with no positional arguments, so these vanish.
# shellcheck disable=SC2016
check "positional-list expansion"        ask   'trun$@cate -s 0 audit.log'
# shellcheck disable=SC2016
check "positional-list, client"          ask   'p$@sql -c "TRUNCATE users"'
# shellcheck disable=SC2016
check "numbered positional expansion"    ask   'trun$1cate -s 0 audit.log'
check "positional list as an operand"    allow 'echo "$@"'
# The backtick is the same construct as $( ) in the older spelling, so an empty
# one rejoins the halves exactly as an empty substitution does.
check "backtick substitution in a name" ask   'trun`true`cate -s 0 audit.log'
check "backtick substitution, client"   ask   'p`true`sql -c "TRUNCATE users"'
check "backtick around a real name"     allow 'echo `true`hello'
# Quoting or assembling the NAME does not help: the rule reads position, never
# the value, so there is no spelling to chase.
# shellcheck disable=SC2016
check "client name split by quotes"      ask  'C=p"s"ql; "$C" -c "truncate users"'
# shellcheck disable=SC2016
check "client name split by backslash"   ask  'C=p\sql; "$C" -c "truncate users"'
# shellcheck disable=SC2016
check "attached subshell command word"   ask  'C=psql; ("$C" -c "truncate users")'
# The bound is load-bearing the other way: unbounded, every unreadable command
# word in a command that merely MENTIONS truncate warns - 17 extra prompts over
# the replay corpus, the english-word false positive in a narrower dress.
# shellcheck disable=SC2016
check "unreadable word, no client named" allow 'C=wc; "$C" -l truncate.txt'
# An expansion ANYWHERE in the command word makes it unreadable: `${IFS}` field-
# splits the word into the client and its arguments after this walk has read it.
# shellcheck disable=SC2016
check "field-split by IFS"               ask  'psql${IFS}-c${IFS}"TRUNCATE users"'
# Bash tokenises on redirection metacharacters and shlex does not, so an
# ATTACHED redirection hides the client inside a single token.
check "attached > redirection"           ask  'psql>out -c "TRUNCATE users"'
check "attached herestring"              ask  'psql<<<"TRUNCATE users"'
check "attached, absolute path"          ask  '/usr/bin/psql<<<"TRUNCATE users"'
check "attached redirection, truncate"   ask  'truncate>log -s 0 audit.log'
# A name rebound STATICALLY carries no expansion at the call site to mark it
# unreadable, so the binding form itself is what fails closed.
check "alias-rebound client"             ask  'alias db=psql; db -c "TRUNCATE users"'
check "hash -p rebound client"           ask  'hash -p /usr/bin/psql db; db -c "TRUNCATE users"'
# ...still bounded by a client being named: a rebind alone is not a client.
check "rebind, no client named"          allow 'alias t=wc; t -l truncate.txt'
# A REMOTE or CONTAINER dispatcher runs its operand: without it in WRAPPERS the
# dispatcher name consumes the command slot and the client reads as an argument.
check "ssh-dispatched client"            ask  'ssh dbhost psql -c "TRUNCATE users"'
check "docker-dispatched client"         ask  'docker exec db psql -c "TRUNCATE users"'
check "kubectl-dispatched client"        ask  'kubectl exec pod -- psql -c "TRUNCATE users"'
# The wrapper scan must normalise attached redirections too, not only the walk.
check "wrapper + attached redirection"   ask  'sudo truncate>log -s 0 audit.log'
# A wrapper or control NAME used as DATA must not reopen command scanning — that
# is the bare-word false positive this walk exists to remove.
check "wrapper name as an operand"       allow 'echo command truncate psql'
check "wrapper name mid-operands"        allow 'grep truncate command psql'
check "control word as an operand"       allow 'echo truncate then psql'
check "esac as an operand"               allow 'echo truncate esac psql'
check "dispatch flag outside find"       allow 'echo truncate -exec psql'
# ...but inside its real dispatcher, -exec still reopens the slot.
check "find -exec truncate"              ask  'find . -name "*.log" -exec truncate -s 0 {} \;'
# ACCEPTED OVER-WARN: split_segments splits at `;;`, so a later spaced case
# PATTERN starts its own segment and reads as a command word. Warning is the
# safe direction; carrying case state across segments would instead miss a
# truncate in a multi-command case BODY, which is a fail-open.
#
# RAISED AGAIN AND DECLINED AGAIN (review round 6). A `;;`-aware state machine
# was built to answer it and reverted unused: `;;` never reaches the walk as a
# token at all, because split_segments has already consumed it, so the code
# could not fire. A rule that cannot fire is worse than none - it certifies a
# case it never read. The fix would have to move into segmentation, where it is
# the fail-open above.
check "spaced later case pattern"        ask  'case x in a) :;; truncate ) echo no;; esac'
# The SQL side pays no such cost: a client name alone names no OPERATION, so the
# same misread pattern stays silent there. The over-warn is coreutils-only.
check "later pattern, client name"       allow 'case x in a) :;; psql ) echo no;; esac'

echo "--- the case construct: subject and patterns are DATA ---"
# Treating case/in/esac as unconditional control tokens made these prompt.
check "case subject is not a command"    allow 'case truncate in x) echo no;; esac'
check "in as a plain operand"            allow 'echo in truncate'

echo "--- real SQL (must warn) ---"
check "TRUNCATE TABLE"                   ask  'psql -c "TRUNCATE TABLE users"'
check "bare TRUNCATE via psql"           ask  'psql -c "TRUNCATE users"'
check "TRUNCATE via mysql -e"            ask  'mysql -e "TRUNCATE orders" shop'
check "TRUNCATE TABLE, no client"        ask  'TRUNCATE TABLE users;'
check "uppercase is matched"             ask  'sqlite3 app.db "truncate table sessions"'

echo "--- bare TRUNCATE through other SQL clients (must warn) ---"
# The client list is an allowlist, so each name it must cover is pinned here.
check "pgcli"                            ask  "pgcli -c 'truncate users'"
check "sqlplus heredoc"                  ask  "sqlplus -S user/pw <<<'truncate users'"
check "snowsql"                          ask  "snowsql -q 'truncate users'"
check "usql"                             ask  "usql pg://h/db -c 'truncate users'"

echo "--- coreutils truncate (must warn: it erases a file in place) ---"
check "truncate as the command word"     ask  'truncate -s 0 .claude/bypass-log.jsonl'
check "truncate after a separator"       ask  'cd /tmp && truncate -s 0 audit.log'
# A wrapper occupies the command-word slot, so position alone would miss this —
# it is the audit-log erasure shape #519 exists to block.
check "env -S wrapped truncate"          ask  "env -S'truncate -s 0 .claude/bypass-log.jsonl' true"
check "xargs-fed truncate"               ask  'echo log | xargs truncate -s 0'
# A wrapper or an absolute path occupies the command slot, so the scanner
# resolves the basename and scans past a known wrapper. Long options are
# irrelevant to the match.
check "sudo + long --size="              ask  'sudo truncate --size=0 audit.log'
check "absolute path + long --size"      ask  '/usr/bin/truncate --size 0 audit.log'
check "env wrapper + --reference"        ask  'env truncate --reference=empty audit.log'
# Option ORDER and spelling must not matter — enumerating destructive flags made
# every new permutation a bypass.
check "flags before --size"             ask  'sudo truncate -c -s 0 audit.log'
check "long --no-create then --size"    ask  'env truncate --no-create --size=0 audit.log'
check "short -r reference"              ask  'sudo truncate -r empty audit.log'
# GNU permutes options AFTER operands, so a flag-keyed match missed these.
check "operand before option"           ask  'sudo truncate audit.log -s 0'
check "operand before long option"      ask  'env truncate audit.log --size=0'
# ...and the same text inside a quoted literal must still be silent. These two
# demands are why detection is delegated to the shlex scanner, not a regex.
check "flags quoted inside a grep -F"   allow 'grep -F "truncate -s" script.sh'
check "flags quoted in a python literal" allow 'python3 -c "print(\"truncate --size\")"'

echo "--- wrappers with option ARGUMENTS (must warn) ---"
# Skipping only dash-tokens stopped at the option argument and missed the command.
check "sudo -u root"                     ask  'sudo -u root truncate -s 0 audit.log'
check "env -u VAR"                       ask  'env -u FOO truncate -s 0 audit.log'
check "timeout with a duration"          ask  'timeout 5 truncate -s 0 audit.log'
check "nice -n 10"                       ask  'nice -n 10 truncate -s 0 audit.log'
# Documented consequence: under a wrapper the guard stops distinguishing operand
# from command word, so this over-warns. Pinned so the trade stays visible.
check "wrapped grep over-warns"          ask  'sudo grep -F truncate script.sh'

echo "--- prefixes that are not the command word (must warn) ---"
check "leading redirect"                 ask  'truncate -s 0 audit.log </dev/null'
check "redirect BEFORE the command"      ask  '</dev/null truncate -s 0 audit.log'
check "exec replaces the shell"          ask  'exec truncate -s 0 audit.log'
# KNOWN LIMIT, parity with the rm scanner: the ANSI-C dollar-quote spelling of a
# command word yields a different shlex token, so it is not detected. Documented
# in the scanner header as exotic and non-blocking for an advisory guard.

echo "--- bash puts these ahead of the command word (must warn) ---"
check "separated redirect target"        ask  'truncate -s 0 audit.log < /dev/null'
check "redirect pair before command"     ask  '< /dev/null truncate -s 0 audit.log'
# Bash dynamic-FD allocation is a redirection, not a command word — in the
# separated form it consumes the following token as its target too.
check "dynamic fd redirect"              ask  '{fd}>/tmp/log truncate -s 0 audit.log'
check "dynamic fd, separated target"     ask  '{fd}> /tmp/log truncate -s 0 audit.log'
check "combined &> redirect"             ask  '&>/tmp/log truncate -s 0 audit.log'
# shellcheck disable=SC2016
check "control keyword then"             ask  'if true; then truncate -s 0 audit.log; fi'
# The CONDITION of if/while/until is an executed command too — these run truncate.
check "if condition"                     ask  'if truncate -s 0 audit.log; then :; fi'
check "while condition"                  ask  'while truncate -s 0 audit.log; do :; done'
check "until condition"                  ask  'until truncate -s 0 audit.log; do :; done'
# A wrapper can pass the command as one QUOTED PAYLOAD rather than as tokens.
check "xargs sh -c payload"              ask  "printf x | xargs sh -c 'truncate -s 0 audit.log'"
check "timeout bash -c payload"          ask  "timeout 5 bash -c 'truncate -s 0 audit.log'"
# ...but a payload where truncate is only an OPERAND must stay silent.
check "wrapped payload, operand only"    allow "printf x | xargs sh -c 'echo truncate'"
check "pipeline negation"                ask  '! truncate -s 0 audit.log'
check "find -exec dispatch"              ask  "find . -name '*.log' -exec truncate -s 0 {} +"

echo "--- constructs that close before a command word (must warn) ---"
check "case pattern"                     ask  'case x in x) truncate -s 0 audit.log;; esac'
check "function body"                    ask  'f(){ truncate -s 0 audit.log; }; f'
# A standalone grouping token is ONLY punctuation, so the lstrip("({") that
# normalises a command word empties it — it then matched nothing and consumed
# the command slot. The bare-word rule this file replaced caught these as text,
# so losing them was a REGRESSION, not a pre-existing limit.
check "subshell group"                   ask  '( truncate -s 0 audit.log )'
check "nested subshell"                  ask  '( ( truncate -s 0 audit.log ) )'
check "subshell after a cd"              ask  '(cd /tmp; truncate -s 0 audit.log)'
check "brace group, spaced"              ask  '{ truncate -s 0 audit.log; }'
# bash allows a LEADING paren on a case pattern, so `(x)` is parenthesis-
# balanced and a balance test misreads it as a command substitution.
check "parenthesised case pattern"       ask  'case x in (x) truncate -s 0 audit.log;; esac'
# CONTAINING a substitution is not being one: this is still a case pattern.
# shellcheck disable=SC2016
# A token may START with a substitution and still end in a case delimiter, so
# the test is whether the token IS one, not whether it begins with one.
# shellcheck disable=SC2016
# An UNQUOTED substitution can expand to NOTHING, leaving the next token as the
# command word — so it must preserve command position, not consume it.
# shellcheck disable=SC2016
# Quoted text spelling a bare opener collapses to an EMPTY substitution once
# shlex drops the quotes; that must not read as a real one.
# shellcheck disable=SC2016
# shellcheck disable=SC2016
check "quoted pattern with a body" ask 'case '"'"'$(x'"'"' in '"'"'$(x'"'"') truncate -s 0 audit.log;; esac'
# shellcheck disable=SC2016
check "quoted opener is not a substitution" ask 'case '"'"'$('"'"' in '"'"'$('"'"') truncate -s 0 audit.log;; esac'
# shellcheck disable=SC2016
check "empty substitution keeps position" ask '$(true) truncate -s 0 audit.log'
# shlex drops quote provenance, so a LITERAL paren inside a substitution counts
# the same as a syntactic one. The test is deliberately strict (exactly one
# paren pair) and over-warns on anything more complex.
# shellcheck disable=SC2016
check "literal paren inside a substitution" ask 'case "(" in $(echo${IFS}'"'"'('"'"')) truncate -s 0 audit.log;; esac'
# shellcheck disable=SC2016
check "pattern that opens with a substitution" ask 'case "x(" in $(echo${IFS}x)\() truncate -s 0 audit.log;; esac'
# shellcheck disable=SC2016
check "case pattern with a substitution" ask 'case x in x$(true)) truncate -s 0 audit.log;; esac'
# ACCEPTED OVER-WARN: shlex strips quote provenance, so a quoted `(` operand is
# indistinguishable from grouping punctuation. Warning is the safe direction —
# same trade as the wrapped-grep case pinned above.
# shellcheck disable=SC2016
check "quoted paren operand over-warns"  ask  'echo "(" truncate'
check "macos caffeinate launcher"        ask  'caffeinate truncate -s 0 audit.log'
check "coproc launcher"                  ask  'coproc truncate -s 0 audit.log'

echo "--- other launchers in the command slot (must warn) ---"
check "setsid"                           ask  'setsid truncate -s 0 audit.log'
check "flock"                            ask  'flock /tmp/l truncate -s 0 audit.log'
check "unshare"                          ask  'unshare -r truncate -s 0 audit.log'

# A wrapper OPTION whose arity is ambiguous must not swallow the interpreter.
# `env -i` takes NO argument while `env -u FOO` takes one, so a single reading
# of the launcher run has to guess - and guessing "takes an argument" consumed
# `bash`, left no interpreter to recognise, and dropped the `-c` payload from
# the scan entirely. `env -i bash -c "rm -rf /etc"` then scanned as though it
# contained no rm at all: a fail-OPEN the pre-rewrite text grep did NOT have,
# found while grinding PR #555. _shell_payloads now reads the run BOTH ways and
# unions the payloads, the same fail-CLOSED treatment _consumer_words already
# applied. Ground truth for the arities: `env -i bash -c "echo hi"` prints hi,
# and `env -u FOO bash -c "echo hi"` prints hi, so bash really is the utility
# in both - only the token OFFSET differs.
echo "--- ambiguous wrapper-option arity must not hide a payload (must warn) ---"
check "env -i hides bash -c"             ask  'env -i bash -c "rm -rf /etc"'
check "env -u FOO hides bash -c"         ask  'env -u FOO bash -c "rm -rf /etc"'
check "env -i sh -c"                     ask  'env -i sh -c "rm -rf /etc"'
check "env -i with assignment too"       ask  'env -i FOO=1 bash -c "rm -rf /etc"'
# ...and the same reading must not start warning on a harmless payload.
check "env -i benign payload"            allow 'env -i bash -c "echo hi"'
check "env -u FOO benign payload"        allow 'env -u FOO bash -c "echo hi"'

# env(1) puts no shell-identifier rule on the NAME, and the shell has already
# removed the quotes by the time env reads the operand. Ground truth:
#   env 'A B=x' bash -c 'echo hi'   -> prints hi, so the child really does run.
# Requiring an identifier (or forbidding whitespace) stopped the launcher walk
# at that operand and dropped the payload -- fail-OPEN, found by litmus on #555.
echo "--- an assignment VALUE that tears across shlex tokens must not hide the payload ---"
# `X=$((1 + 2))` arrives as `X=$((1` / `+` / `2))`, and advancing one token left
# `+` in the command slot: the walk stopped there, _shell_payloads returned [],
# and every gate sharing this detector saw a command with no rm in it. The span
# is NOT rejoined -- an earlier draft balanced delimiters on the RAW token so a
# quoted paren stayed data, and that scanner produced five verified bypasses of
# its own. The span question is dropped instead: a torn value merely SIGNALS
# that the walk may be lost, and an any-position scan for interpreter NAMES
# needs no span at all. See _torn_assignment / _shell_payloads.
# shellcheck disable=SC2016
check "arithmetic value hides bash -c"  ask   'X=$((1 + 2)) bash -c "rm -rf /etc"'
# shellcheck disable=SC2016
check "backtick value hides bash -c"    ask   'X=`printf x` bash -c "rm -rf /etc"'
check "quoted paren is DATA, not an opener" ask 'X="(" bash -c "rm -rf /etc"'
check "quoted backtick is data too"     ask   'X="`" bash -c "rm -rf /etc"'
check "paren inside a quoted value"     ask   'X="ordinary(value" bash -c "rm -rf /etc"'
# shellcheck disable=SC2016
check "multiple assignment prefixes"    ask   'A=1 B=$((2 + 3)) bash -c "rm -rf /etc"'
check "torn value, benign payload"      allow 'X="(" bash -c "echo hi"'
# An unquoted `${...}` tears at the space inside it exactly as `$(( ))` does, and
# `X=${foo:-a b} bash -c "..."` really does run the child (verified). Tracking
# only parens and backticks left the walk stopped at `b}` with the payload unread.
# shellcheck disable=SC2016
check "brace expansion value tears"     ask   'X=${foo:-a b} bash -c "rm -rf /etc"'
# shellcheck disable=SC2016
check "brace tear, benign payload"      allow 'X=${foo:-a b} bash -c "echo hi"'
# A BARE brace is a brace group or a brace expansion, neither of which tears, so
# it must not hold the span open over the words that follow.
check "bare brace value does not tear"  ask   'X=a{1,2} bash -c "rm -rf /etc"'
# An env(1) OPERAND can tear too, and its name obeys no shell-identifier rule,
# so the `\w+=` hint never fired for it. Ground truth: the child really runs.
# shellcheck disable=SC2016
check "torn env operand hides payload"  ask   'env A-B=$((1 + 2)) bash -c "rm -rf /etc"'
# shellcheck disable=SC2016
check "torn env operand, benign"        allow 'env A-B=$((1 + 2)) bash -c "echo hi"'
# When adjacent-quote concatenation makes the raw and cooked token streams
# unalignable, the assignment span cannot be delimited at all — quote provenance
# is exactly what was lost. Both guesses hide the payload (extending swallows the
# interpreter, not extending stops at the tear), so no span is guessed: every
# resumption point is tried and the results unioned. Ground truth: bash runs it.
# shellcheck disable=SC2016
check "unalignable assignment is read"  ask   'X=foo"bar ( baz"$((1 + 2)) bash -c "rm -rf /etc"'
# The two round-2 findings the delimiter scanner could not reach. Both pass now
# with NO code that knows these syntaxes exist, which is the whole claim: `(` is
# structure inside `$((` and data inside `${x:-(}`, and `$[...]` is a delimiter
# context of its own. A scanner has to know that; a scan for interpreter NAMES
# does not. Ground truth: bash runs the child in both.
# shellcheck disable=SC2016
check "paren is data inside \${...}"     ask   'X=${x:-(} bash -c "rm -rf /etc"'
# shellcheck disable=SC2016
check "\$[...] arithmetic tears too"     ask   'X=$[1 + 2] bash -c "rm -rf /etc"'
# shellcheck disable=SC2016
check "\$[...] tear, benign payload"     allow 'X=$[1 + 2] bash -c "echo hi"'
# A quoted interpreter run inside an ARGUMENT stays one shlex token, so it is not
# a separate-token interpreter run and does not fire. This is what keeps the
# over-extraction population narrow.
check "quoted bash -c in an argument"    allow 'echo "bash -c rm -rf /etc"'

echo "--- the any-position fallback is GATED, and what that buys ---"
# `eval` runs its argument as much as any interpreter does; leaving it out of the
# candidate set let a torn assignment carry a deletion straight through.
# shellcheck disable=SC2016
check "torn assignment before eval"     ask   'X=$((1 + 2)) eval "rm -rf /etc"'
# shlex does not know ANSI-C quoting and hands back `$bash`, which bash runs as
# bash. Normalised before the membership test, and again as argv[0] so the
# consumer derives the same name.
check "ANSI-C quoted interpreter"       ask   "env -i \$'bash' -c 'rm -rf /etc'"
# ...and the GATE: when the conservative walk lands on a real command NAME it is
# believed, so a name that only PRINTS its arguments keeps its payload unread.
# Ground truth: `echo bash -c "echo X"` prints the words, it does not run them.
# Without this gate the first warns for nothing and the second could stall a
# fail-CLOSED gate on a `git commit` that never executes.
check "echo does not run its arguments" allow 'echo bash -c "rm -rf /etc"'
check "printf does not run them either" allow 'printf "%s" bash -c "git commit"'
# The fallback still fires when the walk lands on debris no command is named:
# shlex tears `X=$((1 + 2))` and leaves `+` in the command slot.
# shellcheck disable=SC2016
check "debris in the command slot"      ask   'X=$((1 + 2)) bash -c "rm -rf /etc"'

echo "--- the fallback gate needs a SIGNAL, not a shape (must warn) ---"
# `X=$(printf x y)` tears and leaves the perfectly name-shaped `x` in the command
# slot, so a "does argv0 look like a name" test said the walk had succeeded and
# suppressed the fallback. Ground truth: bash runs the commit. The gate now also
# asks whether a token READ AS AN ASSIGNMENT opens something it never closes.
# shellcheck disable=SC2016
check "substitution debris looks like a name" ask 'X=$(printf x y) bash -c "rm -rf /etc"'
# ...and the interpreter NAME may be spelled in ways shlex does not resolve.
# Both verified to execute bash.
check "ANSI-C escaped interpreter"      ask   "X=1 \$'ba\\x73h' -c 'rm -rf /etc'"
check "globbed interpreter path"        ask   'X=1 /bin/ba?h -c "rm -rf /etc"'
check "globbed interpreter, benign"     allow 'X=1 /bin/ba?h -c "echo hi"'
# A word that merely CONTAINS an interpreter name is not one.
check "name containing bash is not bash" allow 'X=1 rebash -c "rm -rf /etc"'

echo "--- an UNREADABLE command word may be an interpreter (must warn) ---"
# Decoding how a name can be spelled is the ladder: $\'...\' concatenation, \\x,
# \\0, \\u, \\U, and the next one after that. So a command word this scan cannot
# READ is refused rather than decoded -- the same inversion careful-guard applies
# at command position. Both of these are verified to execute bash.
check "ANSI-C spliced into the name"    ask   "b\$'a'sh -c 'rm -rf /etc'"
check "unicode escape in the name"      ask   "\$'ba\\u0073h' -c 'rm -rf /etc'"
# ...and an expansion that merely MIGHT be a shell is refused the same way.
# shellcheck disable=SC2016
check "expansion as the command word"   ask   '$SHELL -c "rm -rf /etc"'
# shellcheck disable=SC2016
check "expansion command word, benign"  allow '$SHELL -c "echo hi"'

echo "--- every opener tears a token, not just parens (must warn) ---"
# `${foo:-x y z}` splits into `X=${foo:-x` / `y` / `z}`, leaving the NAME-SHAPED
# `y` in the command slot -- the shape a shape-test cannot catch.
# shellcheck disable=SC2016
check "brace expansion with two words"  ask   'X=${foo:-x y z} bash -c "rm -rf /etc"'
# shellcheck disable=SC2016
check "brace expansion, benign payload" allow 'X=${foo:-x y z} bash -c "echo hi"'

echo "--- the last discriminators removed (must warn) ---"
# A QUOTED literal closer cancels a live opener once shlex drops quote
# provenance, so `X=$(printf")" x y)` arrives balanced and apparently complete
# while bash runs the payload behind it. Delimiter counting was the last grammar
# in this file; the test is now PRESENCE of substitution syntax, which cannot be
# fooled that way and can only over-scan.
# shellcheck disable=SC2016
check "quoted closer fakes a balance"   ask   'X=$(printf")" x y) bash -c "rm -rf /etc"'
# fnmatch has no POSIX bracket CLASSES, so this expands to /bin/bash for the
# shell and to nothing for fnmatch. An unresolved glob is refused, not decoded.
check "POSIX class in the interpreter"  ask   '/bin/ba[[:alpha:]]h -c "rm -rf /etc"'
# An unreadable word may be a shell OR eval, and the two are read differently --
# eval executes its ARGUMENTS, a shell its -c payload. Classifying it as only a
# shell left the eval branch unreachable.
check "ANSI-C spelled eval"             ask   "\$'eval' 'rm -rf /etc'"
check "spliced eval"                    ask   "e\$'va'l 'rm -rf /etc'"
check "ANSI-C eval, benign"             allow "\$'eval' 'echo hi'"
# shellcheck disable=SC2016
check "unalignable, benign payload"     allow 'X=foo"bar ( baz"$((1 + 2)) bash -c "echo hi"'
# A subshell paren rides on the RAW token after group-stripping, so balancing the
# whole token instead of the VALUE added a depth that never closed.
# shellcheck disable=SC2016
check "grouped torn assignment"         ask   '(X=$((1 + 2)) bash -c "rm -rf /etc")'
# A wrapper-shaped token can be an OPTION ARGUMENT rather than the wrapper:
# `env -u command ...` passes `command` to -u. Arity is undecidable statically,
# so both readings are offered and unioned rather than one being chosen.
check "env -u command hides a payload"  ask   'env -u command A-B=1 bash -c "rm -rf /etc"'
check "env -C command hides a payload"  ask   'env -C command A-B=1 bash -c "rm -rf /etc"'
check "env -u command, benign"          allow 'env -u command A-B=1 bash -c "echo hi"'

echo "--- env operands bash would reject, env accepts (must warn) ---"
check "env name with a space"            ask  'env "A B=x" bash -c "rm -rf /etc"'
check "env name with punctuation"        ask  'env "A-B=x" bash -c "rm -rf /etc"'
# ACCEPTED OVER-WARN, and the one the grammar-free scan buys with. Ground truth:
#   command A-B=1 bash -c 'echo RAN'  -> "A-B=1: command not found", nothing runs.
# The payload is extracted anyway, because the scan finds interpreters BY NAME at
# any position and never asks whether the wrapper in front of them actually
# execs. Answering that is shell SEMANTICS, one layer worse than the delimiter
# grammar this scan exists to stop enumerating. Priced before it was accepted:
# diffed against the previous implementation over 29,563 recorded agent commands,
# 361 (1.22%) yield an extra payload, ZERO would newly trip any of the three
# fail-CLOSED gates, and the advisory guard's prompt rate is UNCHANGED --
# 27 of 1,200 sampled commands before and after. The extra payloads are inert.
check "non-env wrapper over-warns (accepted)" ask 'command A-B=1 bash -c "rm -rf /etc"'

echo "--- brace expansion spells a name too (must warn) ---"
# The unreadable-word refusal covered substitutions and globs but not brace
# expansion, and bash expands `ba{s..s}h` to bash and runs it (verified: it
# prints). A name this scan cannot READ is refused, not guessed - the brace
# belongs with the other spellings, not outside them.
check "brace-expanded interpreter"      ask   'ba{s..s}h -c "rm -rf /etc"'
check "brace-expanded, benign payload"  allow 'ba{s..s}h -c "echo hi"'
check "brace-expanded eval"             ask   'ev{a..a}l "rm -rf /etc"'
# ...and a brace that is not a command word must not start warning on its own.
# shellcheck disable=SC2016
check "brace in an argument is not one" allow 'awk "{print \$1}" access.log'

echo "--- the fallback gate must not read ARGUMENTS as assignments (must allow) ---"
# `_torn_assignment` scanned the whole segment, so an assignment-SHAPED argument
# to a command that only prints its arguments tripped the fallback, the payload
# behind it was extracted, and a fail-CLOSED gate blocked a commit that never
# runs. Ground truth: `printf '%s\n' 'X=$(x)' bash -c 'echo RAN'` prints the
# words, it does not run them. The scan now stops at the token the walk stopped
# on, which is the only place debris can be.
# shellcheck disable=SC2016
check "assignment-shaped argument"      allow 'printf "%s" "X=$(x)" bash -c "rm -rf /etc"'
# shellcheck disable=SC2016
check "assignment-shaped arg to echo"   allow 'echo "X=$(x)" bash -c "rm -rf /etc"'
# ...while a real tear in the PREFIX is still caught, which is the case the
# bound must not cost us.
# shellcheck disable=SC2016
check "prefix tear still caught"        ask   'X=$(printf x y) bash -c "rm -rf /etc"'

echo "--- an OPENER names a command, a lone CLOSER is tear debris (must allow) ---"
# The unreadable set takes openers only, for the same reason it never took `]`.
# A tear LEAVES a closer: `X=${foo:-a b}` splits to `X=${foo:-a` / `b}` and
# `X=$(printf x y)` to `X=$(printf` / `x` / `y)`. Reading `b}` / `y)` as
# unreadable command words made the debris its own stand-in shell and the next
# `-c` its option, so a fail-CLOSED gate blocked a command bash never runs.
# Ground truth: `X=$(printf x y) echo -c 'RAN'` prints `-c RAN`, it runs nothing.
# shellcheck disable=SC2016
check "paren debris is not a command"   allow 'X=$(printf x y) echo -c "rm -rf /etc"'
# shellcheck disable=SC2016
check "brace debris is not a command"   allow 'X=${foo:-a b} echo -c "rm -rf /etc"'
# ...and the opener that DOES name a command still resolves. extglob prefixes
# carry neither `*` nor `?`, and whether extglob is enabled is runtime state this
# scan cannot see, so the paren itself is the signal.
check "extglob interpreter"             ask   '/bin/@(ba)sh -c "rm -rf /etc"'
# No benign twin for this spelling: a PAREN in the command word is refused by
# careful-guard's own command-word rule before any payload is read, so it warns
# whatever the payload says. Verified pre-existing on main, where the extglob
# payload is not extracted at all and the prompt comes from that rule alone.

echo "--- the prefix bound must follow the WALK, not a matching value (must warn) ---"
# The bound was recovered by searching the token list for argv[0]'s VALUE, which
# finds the FIRST equal token rather than the occurrence the walk stopped on. In
# `env -u x X=$(printf x y) bash -c '<s>'` the earlier option ARGUMENT is also
# `x`, so the scan covered `env -u x` alone, saw no assignment, suppressed the
# fallback, and missed a payload bash really runs (verified). It is arithmetic
# now -- _command_argv returns a SUFFIX, so len(toks) - len(argv) is the index.
# shellcheck disable=SC2016
check "option arg repeats argv0"        ask   'env -u x X=$(printf x y) bash -c "rm -rf /etc"'
# shellcheck disable=SC2016
check "option arg repeats argv0, benign" allow 'env -u x X=$(printf x y) bash -c "echo hi"'
# Process substitution tears exactly like the others and carries no `$`, so the
# opener list had to name it. Ground truth: the child really runs.
# shellcheck disable=SC2016
check "process substitution value"      ask   'X=<(printf x y) bash -c "rm -rf /etc"'
# shellcheck disable=SC2016
check "process substitution, benign"    allow 'X=<(printf x y) bash -c "echo hi"'
# shellcheck disable=SC2016
check "output process substitution"     ask   'X=>(cat) bash -c "rm -rf /etc"'

echo "--- property matrix: prefix x interpreter spelling x payload ---"
# The example rows above are hand-picked, and twice now a reviewer found a
# combination none of them covered (extglob, and `echo -c` behind a tear). This
# varies the three axes independently instead: every way the walk can be torn,
# crossed with every way the interpreter can be spelled, crossed with a
# destructive and a benign payload. The invariant is the one the whole change
# rests on -- the payload is read no matter how the launcher run is written --
# and it holds in BOTH directions, so a rule that warns by over-extracting
# everything fails the benign half.
# shellcheck disable=SC2016  # the literal `$` IS the input under test
_prefixes=(
  ''                          # no prefix at all
  'X=1 '                      # an ordinary, untorn assignment
  'X=$((1 + 2)) '             # arithmetic tear
  'X=${foo:-a b} '            # brace-expansion tear
  'X=$(printf x y) '          # tear leaving a NAME-shaped token
  'env A-B=$((1 + 2)) '       # env(1) operand, torn, not an identifier
  'env -i '                   # no-arg wrapper option
  'env -u FOO '               # value-taking wrapper option
)
_interps=(
  'bash'                      # named outright
  'sh'
  '/bin/bash'                 # by path
  '/bin/ba?h'                 # by glob
  'ba{s..s}h'                 # by brace expansion
  '/bin/@(ba)sh'              # by extglob
)
for _p in "${_prefixes[@]}"; do
  for _i in "${_interps[@]}"; do
    check "warns: ${_p}${_i}"  ask   "${_p}${_i} -c \"rm -rf /etc\""
    # The benign half is skipped for a PAREN spelling, and only for it. A paren
    # at command-word position is refused by careful-guard's own rule before any
    # payload is read (pre-existing on main), so that row would assert which
    # rule spoke rather than whether the payload was extracted -- and a tearing
    # prefix moves the paren off command position, flipping the answer for a
    # reason this matrix is not about. The destructive half still covers every
    # prefix for this spelling.
    case $_i in *'('*) continue ;; esac
    check "quiet: ${_p}${_i}"  allow "${_p}${_i} -c \"echo hi\""
  done
done

# ACCEPTED LIMIT, pinned so the trade stays visible: a command word held in a
# VARIABLE is not resolved. Detecting it means emulating bash assignment
# semantics - `export`/`declare`/`typeset`/`readonly`, stacked and interleaved,
# their option polarities, and which options assign versus print - and every
# rung of that ladder produced a fresh bypass without silencing a single one of
# the 237 measured prompts. This shape has never appeared in the log; the
# scanner reads command POSITION, not values.
echo "--- a command word held in a variable is NOT resolved (known limit) ---"
# shellcheck disable=SC2016
check "variable command name"            allow 'cmd=truncate; "$cmd" -s 0 audit.log'

echo "--- bare operand, no quotes: command-word position is what decides ---"
check "bare operand to grep"             allow 'grep -F truncate script.sh'
check "bare operand to echo"             allow 'echo truncate'
check "a filename that mentions it"      allow 'cat tests/test-careful-guard-truncate-context.sh'
check "assignment prefix, real command"  ask   'LC_ALL=C truncate -s 0 audit.log'
# The prefix must be read from the RAW token. _cmd_word takes a BASENAME, so a
# value holding a PATH lost the `=` with it — `X=/tmp` normalised to `tmp`, took
# command position, and the real command word behind it read as an operand.
check "assignment whose value is a path" ask   'X=/tmp truncate -s 0 audit.log'
check "path-valued assignment, client"   ask   'PATH=/usr/bin psql -c "TRUNCATE users"'
check "path-valued assignment, benign"   allow 'PATH=/usr/bin git log'

# #585: a token names a command only at COMMAND POSITION, and a closer that was
# QUOTED is data, not syntax. posix shlex erases the quotes before either walk
# sees the token, so the raw spelling has to settle the second half.
echo "--- #585: command position and quote provenance ---"
check "glob operand is not a command"    allow 'grep "*" -r src'
check "quoted paren does not reopen"     allow 'echo "foo)" truncate'
check "unquoted glob at command position" ask  '/bin/* -rf /etc'
# shellcheck disable=SC2016  # the substitution IS the fixture
check "paren closed by a substitution"   ask   'trun$(x=")")cate -s 0 f'
# An EVEN run of backslashes leaves the `)` unescaped, so the pattern really
# does close and the body really does run. Reading `\\)` as escaped was a
# fail-OPEN on a destructive rm.
check "even backslash run still closes"  ask   'case "x\\" in x\\) rm -rf /etc;; esac'
# An UNPARSEABLE segment (an unmatched quote inside a comment) must still reach
# the rm scanner. The #585 gate and the loop it guards share the same
# whitespace-split fallback, so the gate can never be the stricter of the two.
check "unparseable comment, rm"          ask   "rm -rf /etc # '"
check "unparseable comment, wrapped rm"  ask   "sudo rm -rf /etc # '"
# split_segments cuts at the `&` of a SEPARATED redirection, orphaning its
# operand at the head of the next segment. Only a whole-chunk walk rejoins it;
# gating per segment read `out.log` as the command word and skipped the rm.
check "separated redirect, then rm"      ask   '>& out.log rm -rf /etc'
check "separated fd redirect, then rm"   ask   '2>& 1 rm -rf /etc'

# The enumerated cases above each pin ONE shape. They do not exercise the shapes
# in COMBINATION, and combination is where this parser actually failed: the
# wrapper-payload gap survived hand-picked cases because no single case put a
# quoted payload behind a wrapper behind a construct. So generate the product of
# the four dimensions the walk tracks and assert the invariant directly —
# whatever the prefix, construct and wrapper, a client that RUNS must warn.
#
# Positive direction only. The negative direction is deliberately not a property:
# once a wrapper holds the command slot, any later token counts (see the WRAPPERS
# comment in careful-guard.sh), so a client name used as DATA behind a wrapper
# warns ON PURPOSE. The data cases are pinned individually above instead.
echo "--- combination matrix: prefix x construct x wrapper (all must warn) ---"
inner="psql -c 'TRUNCATE users'"
i=0
for prefix in "" "LC_ALL=C " "sudo -u postgres " "env FOO=bar " ">/dev/null "; do
  for wrap in "%s" "watch \"%s\"" "xargs sh -c \"%s\"" "timeout 5 %s"; do
    # shellcheck disable=SC2059  # the format string IS the fixture
    cmd=$(printf "$wrap" "${prefix}${inner}")
    for construct in "%s" "if %s; then :; fi" "case x in x) %s;; esac" \
                     "f(){ %s; }; f" "{ %s; }" "true && %s"; do
      i=$((i+1))
      # shellcheck disable=SC2059  # the format string IS the fixture
      case_cmd=$(printf "$construct" "$cmd")
      check "matrix $i" ask "$case_cmd"
    done
  done
done

# The matrix above varies what comes BEFORE the command word. Adjacency and
# binding vary the command word ITSELF, which is where the parser was bypassed
# twice (an attached redirection, and a name rebound by alias). Cross those forms
# with the same constructs so a construct cannot re-hide one of them.
echo "--- command-word form x construct (all must warn) ---"
j=0
for form in "psql -c 'TRUNCATE users'" \
            "psql>out -c 'TRUNCATE users'" \
            "psql<<<'TRUNCATE users'" \
            "/usr/bin/psql -c 'TRUNCATE users'" \
            "C=psql; \"\$C\" -c 'TRUNCATE users'" \
            "alias db=psql; db -c 'TRUNCATE users'"; do
  for construct in "%s" "if %s; then :; fi" "case x in x) %s;; esac" \
                   "f(){ %s; }; f" "{ %s; }" "true && %s"; do
    j=$((j+1))
    # shellcheck disable=SC2059  # the format string IS the fixture
    form_cmd=$(printf "$construct" "$form")
    check "form $j" ask "$form_cmd"
  done
done

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
