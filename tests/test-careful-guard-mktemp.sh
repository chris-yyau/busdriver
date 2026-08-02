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
cd "$(dirname "$0")/.." || exit 1

GUARD="hooks/gate-scripts/careful-guard.sh"

pass=0 fail=0

# bypassPermissions: every check is live there, so nothing below is masked by
# the auto-mode stand-down.
verdict() {
  local payload out rc
  payload=$(python3 -c '
import json, sys
print(json.dumps({"permission_mode": "bypassPermissions",
                  "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[1]}}))' "$1")
  # Read the exit status too: a startup failure yields empty output, which
  # matches no "ask" and would otherwise report a clean "allow" — a false PASS.
  out=$("$GUARD" <<<"$payload"); rc=$?
  if [[ $rc -ne 0 ]]; then echo "ERROR(rc=$rc)"; return; fi
  if [[ "$out" == *'"permissionDecision":"ask"'* ]]; then echo "ask"; else echo "allow"; fi
}

check() { # name expected command
  local got; got=$(verdict "$3")
  if [[ "$got" == "$2" ]]; then
    echo "PASS: $1"; pass=$((pass+1))
  else
    echo "FAIL: $1 — expected $2 got $got"; fail=$((fail+1))
  fi
}

echo "--- self-created temp dir (must be silent) ---"
# shellcheck disable=SC2016  # every $ below must reach the guard UNexpanded
check "the measured shape"          allow 'T=$(mktemp -d); rm -rf "$T"'
# shellcheck disable=SC2016
check "unquoted expansion"          allow 'd=$(mktemp -d); rm -rf $d'
# shellcheck disable=SC2016
check "braced expansion"            allow 'T=$(mktemp -d); rm -rf "${T}"'
# shellcheck disable=SC2016
check "quoted assignment"           allow 'T="$(mktemp -d)"; rm -rf "$T"'
# shellcheck disable=SC2016
check "backtick assignment"         allow 'T=`mktemp -d`; rm -rf "$T"'
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
