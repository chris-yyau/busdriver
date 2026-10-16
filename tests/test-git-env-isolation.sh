#!/usr/bin/env bash
# Every tests/test-*.sh that invokes git must have, as its first two code lines, a `set -` line and
# then the line that sources tests/lib/git-env-isolation.sh (#967). Nothing can run before the
# guard. Also checks the helper's effect, and that the scan can fail.
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
cd "$(dirname "$0")/.." || exit 1

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

# git as a word on a non-comment line; excludes .git, .github, git-* and *_git.
GIT_WORD='(^|[^[:alnum:]_.-])git([^[:alnum:]_.-]|$)'
SRC_LINE='. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1'

# The second grep reads all its input: `grep -q` would exit early, and under pipefail the writer's
# SIGPIPE (141) would read as "no git" on a large suite.
calls_git() { grep -nE "$GIT_WORD" "$1" | grep -vE '^[0-9]+:[[:space:]]*#' >/dev/null; }
# A suite invokes git if it does so itself or names a repo script that does, directly or through
# further scripts (ack-ledger.sh runs `git rev-parse`, so its suites need the guard with no `git`
# word of their own).
# shortcut: only references spelled with a scripts/ or hooks/ component are followed, so a script
# sourced as "$(dirname "$0")/x.sh" is missed; widen the pattern if one turns up.
invokes_git() { _seen=" "; reaches_git "$1"; }
reaches_git() {
  local p
  case $_seen in *" $1 "*) return 1 ;; esac
  _seen="$_seen$1 "
  calls_git "$1" && return 0
  # Each reference is tried from every component boundary, so $ROOT/skills/x/scripts/y.sh resolves.
  for p in $(grep -vE '^[[:space:]]*#' "$1" | grep -oE '[A-Za-z0-9_./-]*(scripts|hooks)/[A-Za-z0-9_./-]+' | sort -u); do
    while :; do
      [ -f "$p" ] && reaches_git "$p" && return 0
      case $p in */*) p=${p#*/} ;; *) break ;; esac
      case $p in *scripts/*|*hooks/*) ;; *) break ;; esac
    done
  done
  return 1
}

# unguarded <dir>: each <dir>/test-*.sh that invokes git and whose first two code lines are not a
# bare `set -<flags> [pipefail]` line followed directly by SRC_LINE. The set line must hold nothing
# else: `set -u; git status` would run git before the guard.
unguarded() {
  local f code l1 l2
  for f in "$1"/test-*.sh; do
    [ -f "$f" ] && invokes_git "$f" || continue
    code=$(grep -nvE '^[[:space:]]*#|^[[:space:]]*$' "$f" | head -2)
    l1=$(printf '%s\n' "$code" | sed -n 1p); l2=$(printf '%s\n' "$code" | sed -n 2p)
    [[ ${l1#*:} =~ ^set\ -[a-z]+(\ pipefail)?$ ]] || { echo "$f"; continue; }
    { [ "${l2#*:}" = "$SRC_LINE" ] && [ "${l2%%:*}" -eq $(( ${l1%%:*} + 1 )) ]; } || echo "$f"
  done
}

echo "── every git-invoking suite sources the helper first ─────────"
bad=$(unguarded tests)
if [ -z "$bad" ]; then pass "no unguarded suite"; else fail "unguarded: $(echo $bad)"; fi
n=$(for f in tests/test-*.sh; do invokes_git "$f" && echo "$f"; done | wc -l | tr -d ' ')
if [ "$n" -ge 138 ]; then pass "scan sees $n git-invoking suites (138 at #967)"; else fail "scan sees only $n git-invoking suites (expected >= 138)"; fi
if invokes_git tests/test-git-env-isolation.sh; then pass "this suite is inside its own scan"
else fail "this suite is not inside its own scan, so removing its source line would go unnoticed"; fi

echo "── the scan can fail ─────────────────────────────────────────"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf '#!/usr/bin/env bash\nset -u\ngit init -q "$1"\n' > "$T/test-a.sh"
printf '#!/usr/bin/env bash\nset -u\n( cd "$1" && git init -q )\n%s\n' "$SRC_LINE" > "$T/test-b.sh"
# Reaches git only through a repo script, with no `git` word of its own.
printf '#!/usr/bin/env bash\nset -u\nbash scripts/ack-ledger.sh coderabbitai\n' > "$T/test-c.sh"
printf '#!/usr/bin/env bash\nset -u\nR=$(cd "$1" && pwd)\n%s\ngit -C "$R" init -q\n' "$SRC_LINE" > "$T/test-d.sh"
printf '#!/usr/bin/env bash\nX=1\nset -u\n%s\ngit init -q "$1"\n' "$SRC_LINE" > "$T/test-e.sh"
printf '#!/usr/bin/env bash\nset -u; git status --short\n%s\n' "$SRC_LINE" > "$T/test-i.sh"
printf '#!/usr/bin/env bash\n# header\nset -u\n%s\n\ngit init -q "$1"\n' "$SRC_LINE" > "$T/test-f.sh"
printf '#!/usr/bin/env bash\nset -u\n# git init in a comment\nls .github\n' > "$T/test-g.sh"
# Larger than a pipe buffer: an early-exiting reader would SIGPIPE the scan and hide this suite.
{ printf '#!/usr/bin/env bash\nset -u\n'; for _i in $(seq 3000); do echo 'git status --short  # padding to pass the pipe buffer'; done; } > "$T/test-h.sh"
got=$(unguarded "$T" | sed "s|$T/||" | tr '\n' ' ')
if [ "$got" = "test-a.sh test-b.sh test-c.sh test-d.sh test-e.sh test-h.sh test-i.sh " ]; then
  pass "missing, late, after-\$(cd), after-code, after-set-line-command, large-suite and via-script source lines are reported; guarded and git-free suites are not"
else fail "negative control reported: '$got'"; fi

echo "── the helper clears inherited repository and config env ─────"
R="$T/repo"; git init -q "$R"
out=$(env GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/x GIT_COMMON_DIR=/x \
      GIT_OBJECT_DIRECTORY=/x GIT_ALTERNATE_OBJECT_DIRECTORIES=/x GIT_CEILING_DIRECTORIES=/x GIT_PREFIX=x/ GIT_CONFIG=/x GIT_CONFIG_PARAMETERS="'core.hookspath=/evil'" \
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/evil \
      bash -c '. tests/lib/git-env-isolation.sh || exit 9
        for v in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_PREFIX GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0; do
          [ -z "${!v+x}" ] || echo "still set: $v"; done
        echo "count=$GIT_CONFIG_COUNT global=$GIT_CONFIG_GLOBAL nosystem=$GIT_CONFIG_NOSYSTEM"
        echo "hooksPath=$(git -C "$1" config --get core.hooksPath)"' _ "$R" 2>&1)
want="count=0 global=/dev/null nosystem=1
hooksPath="
if [ "$out" = "$want" ]; then pass "poisoned GIT_* env is cleared and no injected config reaches git"
else fail "helper left: $out"; fi
# Every variable git itself lists as repository-local, the ones it omits that review found, and one
# no list names, are cleared. GIT_CONFIG_COUNT is on git's list but re-exported as 0, checked above.
vars="$(git rev-parse --local-env-vars | grep -vx GIT_CONFIG_COUNT | tr '\n' ' ')GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_DEFAULT_HASH GIT_ZZ_967"
left=$(for v in $vars; do printf '%s=/x\0' "$v"; done | xargs -0 sh -c 'exec env "$@" bash -c ". tests/lib/git-env-isolation.sh || exit 9
  for v in $0; do [ -z \"\${!v+x}\" ] || echo \$v; done"' "$vars" 2>&1)
if [ -z "$left" ] && [ "$(echo $vars | wc -w)" -ge 18 ]; then pass "every inherited GIT_* variable is cleared (git's repository-local list, GIT_NAMESPACE, GIT_DEFAULT_HASH, an arbitrary GIT_ZZ_967)"
else fail "helper left set: '$left' (of: $vars)"; fi
# Positive control: the same poison without the helper does reach git.
leak=$(env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/evil git -C "$R" config --get core.hooksPath)
if [ "$leak" = /evil ]; then pass "control: without the helper the injected config reaches git"
else fail "control: injected config did not reach git ('$leak'), so the check above proves nothing"; fi

echo ""
echo "git-env-isolation: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
