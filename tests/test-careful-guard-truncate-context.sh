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
cd "$(dirname "$0")/.." || exit 1

GUARD="hooks/gate-scripts/careful-guard.sh"

pass=0 fail=0

# <command> -> ask|allow|ERROR. bypassPermissions: every check is live there, so
# nothing below is masked by the auto-mode stand-down.
verdict() {
  local payload out rc
  payload=$(python3 -c '
import json, sys
print(json.dumps({"permission_mode": "bypassPermissions",
                  "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[1]}}))' "$1")
  # Read the guard'"'"'s exit status too: a startup failure yields empty output,
  # which matches no "ask" and would report a clean "allow" — a false PASS.
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

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
