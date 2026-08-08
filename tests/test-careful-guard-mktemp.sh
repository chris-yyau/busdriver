#!/usr/bin/env bash
# test-careful-guard-mktemp.sh
# A variable this same command bound to `$(mktemp -d)` names a directory the
# command itself just created, so removing it cannot destroy anything that
# existed beforehand.
#
# Measured over ~/.claude/watch-hooks.log — 209 real Bash permission prompts over
# six days — `rm -rf "$T"` after a `T=$(mktemp -d)` was 45 of them: 22%, the
# second largest interruption source after `out`.
#
# Clearing the WRONG variable is a fail-OPEN, so attribution is strict and this
# file pins BOTH directions: the carve-out arms only when every assignment to the
# name, at command-prefix position, comes from mktemp — and every route that can
# rebind the name by other means must still warn.
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

# bypassPermissions: every check is live there, so nothing below is masked by
# the auto-mode stand-down.
# shellcheck source=tests/lib/careful-guard-harness.sh
# shellcheck disable=SC1091  # the source= path above needs `shellcheck -x`
. "$_HERE/lib/careful-guard-harness.sh" || exit 1

echo "--- self-created temp dir (must be silent) ---"
# shellcheck disable=SC2016  # every $ below must reach the guard UNexpanded
check "the measured shape"          allow 'T=$(mktemp -d); rm -rf "$T"'
# UNQUOTED is not safe even for a temp dir: bash word-splits the expansion, so
# a TMPDIR containing a space makes `rm -rf $d` remove more than the new
# directory. The carve-out therefore requires a QUOTED expansion.
# shellcheck disable=SC2016
check "unquoted expansion warns"    ask   'd=$(mktemp -d); rm -rf $d'
# Quoting elsewhere is not proof about THIS rm — the check is segment-scoped.
# shellcheck disable=SC2016
check "quoted elsewhere, unquoted rm" ask 'T=$(mktemp -d); echo "$T"; rm -rf $T'
# ...and EVERY occurrence must be quoted, not merely one of them.
# shellcheck disable=SC2016
check "one target quoted, one not"  ask   'T=$(mktemp -d); rm -rf $T "$T"'
# Single quotes do not expand: the target is a LITERAL path named for the
# variable, not the new directory, so clearing it would be a fail-open.
# shellcheck disable=SC2016
check "single-quoted target"        ask   'T=$(mktemp -d); rm -rf '"'"'$T'"'"''
# shellcheck disable=SC2016
check "single-quoted braced target" ask   'T=$(mktemp -d); rm -rf '"'"'${T}'"'"''
# A doubled quote is an EMPTY word, so the expansion between two of them is
# unquoted and still word-splits.
# shellcheck disable=SC2016
check "expansion between empty words" ask 'T=$(mktemp -d); rm -rf ""$T""'
# Quote CONCATENATION puts no `$T` in the raw text at all, so the target is a
# LITERAL path named for the variable. The proof must be the PRESENCE of a
# quoted expansion, not merely the absence of an unquoted one.
# shellcheck disable=SC2016
check "concatenated quoting"        ask   'T=$(mktemp -d); rm -rf "$""T"'
# shellcheck disable=SC2016
check "quoted dollar, bare name"    ask   'T=$(mktemp -d); rm -rf "$"T'
# The braces must BALANCE. Written independently optional, the proof pattern
# accepted `"$T}"` — which bash expands to the directory PLUS a literal `}` —
# as proof about a target that is not the directory at all.
# shellcheck disable=SC2016
check "unbalanced closing brace"    ask   'T=$(mktemp -d); rm -rf "$T}"'
# shellcheck disable=SC2016
check "unbalanced opening brace"    ask   'T=$(mktemp -d); rm -rf "${T"'
# A SINGLE quote anywhere in the segment voids the proof: shlex has dropped
# provenance, so a genuine `"$T"` cannot be told from a token that merely COOKS
# to the same text.
# shellcheck disable=SC2016
check "single quote defeats the proof" ask 'T=$(mktemp -d); X="$T" rm -rf '"'"'$'"''"'T'"'"''
# ...and so does a doubled DOUBLE quote, the concatenation signature: an
# assignment must not be able to supply the proof for a literal target.
# shellcheck disable=SC2016
check "assignment supplies a decoy"  ask   'T=$(mktemp -d); X="$T" rm -rf "$""T"'
# shellcheck disable=SC2016
check "braced expansion"            allow 'T=$(mktemp -d); rm -rf "${T}"'
# A brace group run by a SUBSHELL binds nothing in the parent: the rm then
# deletes whatever T was inherited, not the new directory.
# shellcheck disable=SC2016
check "piped brace group"           ask   '{ :; T=$(mktemp -d); } | cat; rm -rf "$T"'
# shellcheck disable=SC2016
check "backgrounded brace group"    ask   '{ :; T=$(mktemp -d); } & wait; rm -rf "$T"'
# shellcheck disable=SC2016
check "coproc brace group"          ask   'coproc { T=$(mktemp -d); }; rm -rf "$T"'
# A `function` definition defers the body, and invoking it in a pipeline runs it
# in a subshell - the parens the other void catches are absent from this form.
# shellcheck disable=SC2016
check "function body assignment"    ask   'function f { :; T=$(mktemp -d); }; f | cat; rm -rf "$T"'
# Redirections may sit between the closing brace and the operator; the group is
# still run by a subshell.
# shellcheck disable=SC2016
check "redirected piped group"      ask   '{ :; T=$(mktemp -d); } >/dev/null | cat; rm -rf "$T"'
# shellcheck disable=SC2016
check "redirected background group" ask   '{ :; T=$(mktemp -d); } 2>&1 & wait; rm -rf "$T"'
# ...and the redirection operand may be quoted or contain spaces.
# shellcheck disable=SC2016
check "quoted redirect operand"     ask   '{ :; T=$(mktemp -d); } >"some file" | cat; rm -rf "$T"'
# ...or escaped rather than quoted.
# shellcheck disable=SC2016
check "escaped redirect operand"    ask   '{ :; T=$(mktemp -d); } >some\ file | cat; rm -rf "$T"'
# ...or CONCATENATED from several fragments.
# shellcheck disable=SC2016
check "concatenated redirect operand" ask '{ :; T=$(mktemp -d); } >"some"'"'"' file'"'"' | cat; rm -rf "$T"'
# ...or a substitution that itself contains spaces.
# shellcheck disable=SC2016
check "substitution redirect operand" ask '{ :; T=$(mktemp -d); } >$(printf %s /dev/null) | cat; rm -rf "$T"'
# ...and `>&` / `>|` are redirections too.
# shellcheck disable=SC2016
check "fd-dup redirect operand"     ask   '{ T=$(mktemp -d); } >& out | cat; rm -rf "$T"'
# shellcheck disable=SC2016
check "clobber redirect operand"    ask   '{ T=$(mktemp -d); } >| out | cat; rm -rf "$T"'
# ...a plain brace group is NOT a subshell and must stay silent.
# shellcheck disable=SC2016
check "plain brace group nearby"    allow 'T=$(mktemp -d); { echo hi; } ; rm -rf "$T"'
# shellcheck disable=SC2016
check "quoted assignment"           allow 'T="$(mktemp -d)"; rm -rf "$T"'
# shellcheck disable=SC2016
check "backtick assignment"         allow 'T=`mktemp -d`; rm -rf "$T"'
# At command position the rm scan reads GLOBS too — `/bin/r?` reaches the real
# binary while spelling a name in no set. Bounded by what FOLLOWS: a match only
# warns when a recursive flag sits in the same argv, so a bare `*` stays silent.
check "glob-spelled rm"             ask  '/bin/r? -rf /etc'
check "brace-spelled rm"            ask  '/bin/r{m,m} -rf /etc'
check "bracket-spelled rm"          ask  '/bin/r[m] -rf /etc'
# An expansion can supply the field separators for the WHOLE argv, so `-rf`
# never reached the recursive check as its own token.
# shellcheck disable=SC2016
check "argv inside a single token"  ask  '${IFS}rm${IFS}-rf${IFS}/etc'
# ...and the OPTION tokens are normalised too: `rm $(true)-rf /etc` is a
# recursive delete once the substitution vanishes, and leaving the rest of the
# argv raw meant the flag never reached the recursive check.
# shellcheck disable=SC2016
check "expansion-prefixed flag"     ask  'rm $(true)-rf /etc'
# shellcheck disable=SC2016
check "empty-expansion flag"        ask  'rm ${EMPTY}-rf /etc'
# ...and a NESTED expansion separates fields just as well.
# shellcheck disable=SC2016
check "nested separator argv"       ask  '${x:-${IFS}}rm${x:-${IFS}}-rf${x:-${IFS}}/etc'
check "glob operand is not a name"  allow 'ls *'
check "recursive chmod is not rm"   allow 'chmod -R 777 build'
# A BACKSLASH voids the proof the same way a single quote does. Bash reads an
# escaped letter as itself, so `$\T` is the LITERAL path spelled by the variable
# name — and the survivor search looks for `$T`, which that spelling does not
# contain. The carve-out cleared on the real expansion beside it while a path
# the command never created was being deleted.
# shellcheck disable=SC2016
check "escaped sigil beside the proof" ask 'T=$(mktemp -d); rm -rf "$T" $\T'
# shellcheck disable=SC2016
check "escaped name in the target"     ask 'T=$(mktemp -d); rm -rf "$T" $\{T\}'
# shellcheck disable=SC2016
check "absolute mktemp path"        allow 'T=$(/usr/bin/mktemp -d); rm -rf "$T"'
# A temp FILE is as self-created as a temp dir.
# shellcheck disable=SC2016
check "mktemp without -d"           allow 'T=$(mktemp); rm -rf "$T"'
# shellcheck disable=SC2016
check "chained with real work"      allow 'W=$(mktemp -d) && git -C "$W" init -q && rm -rf "$W"'
# shellcheck disable=SC2016
check "reassigned then reused"      allow 'T=$(mktemp -d); rm -rf "$T"; T=$(mktemp -d); rm -rf "$T"'
# A block only makes assignments that FOLLOW it conditional.
# shellcheck disable=SC2016
check "assignment before a loop"    allow 'T=$(mktemp -d); for f in a b; do touch "$T/$f"; done; rm -rf "$T"'
# shellcheck disable=SC2016
check "two temp dirs"               allow 'A=$(mktemp -d); B=$(mktemp -d); rm -rf "$A" "$B"'

echo "--- the name must be PROVABLY a temp dir (must still warn) ---"
# No assignment in this command string at all — the value is inherited and
# unknowable, which is the pre-existing behaviour and stays.
# shellcheck disable=SC2016
check "no assignment in string"     ask   'rm -rf "$T"'
# shellcheck disable=SC2016
check "assigned from a real path"   ask   'T=/important/data; rm -rf "$T"'
# shellcheck disable=SC2016
check "reassigned after mktemp"     ask   'T=$(mktemp -d); T=/etc; rm -rf "$T"'
# Conservative on purpose: order is not tracked, so ANY non-mktemp assignment to
# the name disqualifies it.
# shellcheck disable=SC2016
check "assigned both ways"          ask   'T=/etc; T=$(mktemp -d); rm -rf "$T"'
# An assignment PREFIX to a command sets it only in that command environment.
# shellcheck disable=SC2016
check "assignment prefixes a command" ask 'T="$(mktemp -d)" true; rm -rf "$T"'
# The assignment is an ARGUMENT to echo, not a command prefix — it never runs.
# shellcheck disable=SC2016
check "assignment inside a literal" ask   'echo "T=$(mktemp -d)"; rm -rf "$T"'
# shellcheck disable=SC2016
check "a different variable"        ask   'T=$(mktemp -d); rm -rf "$OTHER"'

echo "--- the RHS must be ONE complete, plain mktemp substitution (must warn) ---"
# shlex splits an unquoted `$(mktemp -d)` in two, so matching only how the RHS
# BEGINS accepts these — whose values are not temp dirs at all.
# shellcheck disable=SC2016
check "text appended after it"      ask   'T=$(mktemp -d)x; rm -rf "$T"'
# shellcheck disable=SC2016
check "fallback to a real path"     ask   'T=$(mktemp -d 2>/dev/null || echo /etc); rm -rf "$T"'
# shellcheck disable=SC2016
check "second command in the RHS"   ask   'T=$(mktemp -d; echo /etc); rm -rf "$T"'
# shellcheck disable=SC2016
check "nested expansion in the RHS" ask   'T=$(mktemp -d --tmpdir="$EVIL"); rm -rf "$T"'
# shellcheck disable=SC2016
check "copied into another name"    ask   'A=$(mktemp -d); B=$A; rm -rf "$B"'
# `-u`/`--dry-run` PRINTS a candidate name without creating it, so another
# process can occupy that path before the rm runs - it never establishes the
# name is self-created.
# shellcheck disable=SC2016
check "mktemp -u is not a creation"  ask   'T=$(mktemp -u); rm -rf "$T"'
# shellcheck disable=SC2016
check "mktemp --dry-run"            ask   'T=$(mktemp --dry-run); rm -rf "$T"'
# shellcheck disable=SC2016
check "bundled short -qu"           ask   'T=$(mktemp -qu); rm -rf "$T"'
# Bash strips quoting/escapes before mktemp reads its options, and a bundle can
# carry an attached argument, so these are all just `-u` and a text match sees
# none of them. GNU also accepts unambiguous long-option abbreviations.
# shellcheck disable=SC2016
check "escaped -\\u"                 ask   'T=$(mktemp -\u); rm -rf "$T"'
# shellcheck disable=SC2016
check "bundle with attached arg"    ask   'T=$(mktemp -up/tmp); rm -rf "$T"'
# shellcheck disable=SC2016
check "abbreviated --dr"            ask   'T=$(mktemp --dr); rm -rf "$T"'
# ...but a -p argument that merely contains the letter u must stay silent.
# shellcheck disable=SC2016
check "-p path containing u"        allow 'T=$(mktemp -p /usr/local/tmp -d); rm -rf "$T"'
# The check is INVERTED and fail-CLOSED: it proves the invocation CREATES.
# A form this parser cannot read - here brace expansion, which bash resolves
# to `-u -d` long after the scan - is refused rather than assumed safe.
# shellcheck disable=SC2016
check "brace-expanded options"      ask   'T=$(mktemp -{u,d} XXXXXX); rm -rf "$T"'
# ...and an ATTACHED -p argument is the option argument, not more option
# letters, so a `u` inside it must not read as `-u`.
# shellcheck disable=SC2016
check "attached -p argument"        allow 'T=$(mktemp -puser-tmp -d); rm -rf "$T"'
# An OPERAND can smuggle an option through brace expansion too.
# shellcheck disable=SC2016
check "brace-expanded operand"      ask   'T=$(mktemp {,-u} XXXXXX); rm -rf "$T"'
# --tmpdir takes an OPTIONAL argument that GNU requires be ATTACHED with `=`,
# so a separate token after it is NOT its argument and must still be scanned.
# shellcheck disable=SC2016
check "--tmpdir does not eat -u"    ask   'T=$(mktemp --tmpdir -u); rm -rf "$T"'
# ...but --suffix REQUIRES its argument and takes it as a separate token.
# shellcheck disable=SC2016
check "--suffix takes its argument" allow 'T=$(mktemp -d --suffix .bak); rm -rf "$T"'
# The metacharacter refusal covers option ARGUMENTS too, not just operands.
# shellcheck disable=SC2016
check "brace inside an option arg"  ask   'T=$(mktemp -p {/tmp,-u} XXXXXX); rm -rf "$T"'
# macOS `-t prefix` and GNU `-t` both preserve creation.
# shellcheck disable=SC2016
check "macos -t prefix"             allow 'T=$(mktemp -d -t guard); rm -rf "$T"'
# `--` terminates options, so a template that merely LOOKS like one is an operand.
# shellcheck disable=SC2016
check "option terminator --"        allow 'T=$(mktemp -- -u.XXXXXX); rm -rf "$T"'

echo "--- the assignment must actually reach the rm (must warn) ---"
# ORDER matters: this rm runs against the INHERITED T, before any assignment.
# shellcheck disable=SC2016
check "rm precedes the assignment"  ask   'rm -rf "$T"; T=$(mktemp -d)'
# Only a STANDARD mktemp counts - an arbitrary binary named mktemp can print
# /etc without creating anything, and a hyphen is a word boundary so
# `mktemp-evil` must not read as mktemp either.
# shellcheck disable=SC2016
check "mktemp-prefixed binary"      ask   'T=$(mktemp-evil -d); rm -rf "$T"'
# Single quotes make it a LITERAL string, not a substitution.
# shellcheck disable=SC2016
check "single-quoted RHS"           ask   "T='\$(mktemp -d)'; rm -rf \"\$T\""
# shellcheck disable=SC2016
check "untrusted mktemp path"       ask   'T=$(/tmp/evil/mktemp -d); rm -rf "$T"'
# shellcheck disable=SC2016
check "relative mktemp path"        ask   'T=$(./mktemp -d); rm -rf "$T"'
# A child shell cannot change the parent binding.
# shellcheck disable=SC2016
check "assigned in a child shell"   ask   'bash -c '"'"'T=$(mktemp -d)'"'"'; rm -rf "$T"'
# A conditional or subshell assignment leaves the name inherited at the `rm`.
# shellcheck disable=SC2016
check "behind ||"                   ask   'true || T=$(mktemp -d); rm -rf "$T"'
# shellcheck disable=SC2016
check "behind &&"                   ask   'false && T=$(mktemp -d); rm -rf "$T"'
# shellcheck disable=SC2016
check "backgrounded with &"         ask   'T=$(mktemp -d) & wait; rm -rf "$T"'
# shellcheck disable=SC2016
check "printf -v with a computed name" ask 'T=$(mktemp -d); name=T; printf -v "$name" /etc; rm -rf "$T"'
# shellcheck disable=SC2016
check "inside a pipeline subshell"  ask   'T=$(mktemp -d) | cat; rm -rf "$T"'

echo "--- a COMPOUND command hides a subshell (must warn) ---"
# split_segments gives an assignment inside `( ... )` a plain `;`, so it reads
# as a parent-shell binding when it only ever ran in the subshell.
# shellcheck disable=SC2016
check "assignment inside a subshell" ask   '( :; T=$(mktemp -d); ); rm -rf "$T"'
# shellcheck disable=SC2016
check "bare subshell assignment"    ask   '(T=$(mktemp -d)); rm -rf "$T"'

echo "--- mktemp itself, or the binding, redefinable from outside (must warn) ---"
# shellcheck disable=SC2016
check "shell function shadows it"   ask   'mktemp(){ echo /etc; }; T=$(mktemp -d); rm -rf "$T"'
# shellcheck disable=SC2016
check "function keyword form"       ask   'function mktemp { echo /etc; }; T=$(mktemp -d); rm -rf "$T"'
# shellcheck disable=SC2016
# shellcheck disable=SC2016
check "alias shadows mktemp"        ask   'shopt -s expand_aliases; alias mktemp="printf /etc"; T=$(mktemp -d); rm -rf "$T"'
# shellcheck disable=SC2016
check "PATH written via printf -v"  ask   'printf -v PATH /tmp/evil:/bin; T=$(mktemp -d); rm -rf "$T"'
# shellcheck disable=SC2016
check "printf -v with a QUOTED name" ask  'T=$(mktemp -d); printf -v "T" /etc; rm -rf "$T"'
# shellcheck disable=SC2016
check "PATH prepended"              ask   'PATH=/tmp/evil:$PATH; T=$(mktemp -d); rm -rf "$T"'
# A sourced file runs in THIS shell and can reassign the name.
# shellcheck disable=SC2016
check "source between the two"      ask   'T=$(mktemp -d); source /tmp/rebind.sh; rm -rf "$T"'
# shellcheck disable=SC2016
check "dot-source between the two"  ask   'T=$(mktemp -d); . /tmp/rebind.sh; rm -rf "$T"'
# shellcheck disable=SC2016
check "eval between the two"        ask   'T=$(mktemp -d); eval "T=/etc"; rm -rf "$T"'

# An assignment inside a control block may never run.
# shellcheck disable=SC2016
check "assignment in an if block"   ask   'if false; then T=$(mktemp -d); fi; rm -rf "$T"'
# shellcheck disable=SC2016
check "assignment in a while block" ask   'while read x; do T=$(mktemp -d); done; rm -rf "$T"'

echo "--- rebinding by a route other than assignment (must warn) ---"
# Spellings that rebind without producing a plain `NAME=` token.
# shellcheck disable=SC2016
check "append with +="              ask   'T=$(mktemp -d); T+=/etc; rm -rf "$T"'
# shellcheck disable=SC2016
check "array element assignment"    ask   'T=$(mktemp -d); T[0]=/etc; rm -rf "$T"'
# shellcheck disable=SC2016
check "printf -v into the name"     ask   'T=$(mktemp -d); printf -v T /etc; rm -rf "$T"'
# shellcheck disable=SC2016
check "select rebinds the name"     ask   'T=$(mktemp -d); select T in /etc; do rm -rf "$T"; break; done <<<1'
# shellcheck disable=SC2016
check "for-loop rebinds the name"   ask   'T=$(mktemp -d); for T in /etc /usr; do rm -rf "$T"; done'
# bash expands a GLOB against filenames before running the builtin, so with a
# `docs` directory present `read d*` becomes `read docs`.
# shellcheck disable=SC2016
check "read with a glob name"       ask   'docs=$(mktemp -d); read d* <<< /etc; rm -rf "$docs"'
# shellcheck disable=SC2016
check "read with a backtick name"   ask   'T=$(mktemp -d); read "`printf T`" <<< /etc; rm -rf "$T"'
# The builtin operand can be an EXPANSION, choosing its target at runtime.
# shellcheck disable=SC2016
check "read with a computed name"   ask   'T=$(mktemp -d); N=T; read "$N" <<< /etc; rm -rf "$T"'
# shellcheck disable=SC2016
check "read rebinds the name"       ask   'T=$(mktemp -d); read T < paths.txt; rm -rf "$T"'
# shellcheck disable=SC2016
check "default-assign expansion"    ask   'T=$(mktemp -d); rm -rf "${T:=/etc}"'
# `let` rewrites the name through arithmetic evaluation, so `let T++` never
# produces a plain `T=` token for the textual scan to catch.
# shellcheck disable=SC2016
check "let arithmetic increment"    ask   'T=$(mktemp -d); let T++; rm -rf "$T"'
# shellcheck disable=SC2016
check "let arithmetic assignment"   ask   'T=$(mktemp -d); let T=5; rm -rf "$T"'
# `read -aT` (no space) assigns into T exactly like `read -a T` does; the
# identifier scan alone would see the joined token "aT" and miss it.
# shellcheck disable=SC2016
check "read attached array flag"    ask   'T=$(mktemp -d); read -aT <<< /etc; rm -rf "$T"'
# Attached form with a SPACE-separated name still warns via the ordinary path.
# shellcheck disable=SC2016
check "read -a with a separate name" ask  'T=$(mktemp -d); read -a T <<< /etc; rm -rf "$T"'
# The attached-flag match runs over Bash IDENTIFIER characters, not letters. A
# letters-only class shipped first and let every one of these through: the name
# is what follows the flag, and names carry digits and underscores.
# shellcheck disable=SC2016
check "attached flag, digit in name" ask  'T2=$(mktemp -d); read -aT2 <<< /etc; rm -rf "$T2"'
# shellcheck disable=SC2016
check "attached flag, underscore"    ask  'T_X=$(mktemp -d); read -aT_X <<< /etc; rm -rf "$T_X"'
# shellcheck disable=SC2016
check "attached flag in a cluster"   ask  'T2=$(mktemp -d); read -raT2 <<< /etc; rm -rf "$T2"'
# Quotes around the option do not change which name it binds.
# shellcheck disable=SC2016
check "attached flag, quoted option" ask  'T=$(mktemp -d); read "-aT" <<< /etc; rm -rf "$T"'
# The carve-out must SURVIVE for a digit-carrying name nothing rebinds - the
# widened class must not turn into a blanket over-warn.
# shellcheck disable=SC2016
check "digit name, never rebound"    allow 'T2=$(mktemp -d); rm -rf "$T2"'

echo "--- destinations bash writes without naming them ---"
# A bare `read` fills REPLY and `getopts` fills OPTARG/OPTIND on every call, so
# the name never appears in the invocation for the operand scan to find.
# shellcheck disable=SC2016
check "bare read fills REPLY"       ask   'REPLY=$(mktemp -d); read <<< /important/data; rm -rf "$REPLY"'
# shellcheck disable=SC2016
check "getopts fills OPTARG"        ask   'OPTARG=$(mktemp -d); getopts "a:" o; rm -rf "$OPTARG"'
# shellcheck disable=SC2016
check "getopts fills OPTIND"        ask   'OPTIND=$(mktemp -d); getopts "a:" o; rm -rf "$OPTIND"'
# shellcheck disable=SC2016
check "mapfile fills MAPFILE"       ask   'MAPFILE=$(mktemp -d); mapfile < /etc/hosts; rm -rf "$MAPFILE"'
# `wait -p` and `coproc` DO name their destination - they were simply missing
# from the builtin list entirely.
# shellcheck disable=SC2016
check "wait -p names the target"    ask   'T=$(mktemp -d); sleep 0 & wait -p T; rm -rf "$T"'
# These names must keep the exemption when the builtin that writes them never
# runs, or the map degrades into an unconditional over-warn.
# shellcheck disable=SC2016
check "REPLY, no read in sight"     allow 'REPLY=$(mktemp -d); rm -rf "$REPLY"'
# shellcheck disable=SC2016
check "OPTARG, no getopts"          allow 'OPTARG=$(mktemp -d); rm -rf "$OPTARG"'
# A read that writes SOMEWHERE ELSE must not disturb an unrelated temp dir.
# shellcheck disable=SC2016
check "read into another name"      allow 'T=$(mktemp -d); read other < /etc/hosts; rm -rf "$T"'

echo "--- ONLY the bare expansion clears; any suffix warns ---"
# If mktemp FAILED, T is empty - so "$T/" is / and "$T/etc" is /etc. No suffix can
# be proven to stay inside the directory, and none was ever observed in the log.
# shellcheck disable=SC2016
check "trailing slash is /"         ask   'T=$(mktemp -d); rm -rf "$T/"'
# shellcheck disable=SC2016
check "literal suffix"              ask   'T=$(mktemp -d); rm -rf "$T/.github"'
# shellcheck disable=SC2016
check "parent via .."               ask   'T=$(mktemp -d); rm -rf "$T/.."'
# shellcheck disable=SC2016
check "grandparent via ../.."       ask   'T=$(mktemp -d); rm -rf "$T/../.."'
# shellcheck disable=SC2016
check "expansion in the suffix"     ask   'T=$(mktemp -d); rm -rf "$T/$sub"'
# shellcheck disable=SC2016
check "backtick in the suffix"      ask   'T=$(mktemp -d); rm -rf "$T/`printf ../..`"'
# shellcheck disable=SC2016
check "brace expansion suffix"      ask   'T=$(mktemp -d); rm -rf $T/{safe,../..}'
# `${T%/*}` strips the last path component — that is the PARENT, not the temp dir.
# shellcheck disable=SC2016
check "parent via % stripping"      ask   'T=$(mktemp -d); rm -rf "${T%/*}"'
# shellcheck disable=SC2016
check "prefix-matched name"         ask   'T=$(mktemp -d); rm -rf "$TMPDIR"'

echo "--- an unsafe sibling in the same command still warns ---"
# shellcheck disable=SC2016
check "temp dir plus /etc/nginx"    ask   'T=$(mktemp -d); rm -rf "$T" /etc/nginx'

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
