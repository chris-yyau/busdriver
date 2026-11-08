#!/bin/bash
# tests/test-ultra-oracle-launch.sh — spec §3 launch argv and env, §4 process group, §2 cleanup and sweep.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)" && [ -n "$T" ] || { echo "FAIL: mktemp"; exit 1; }   # never let the rm -rf trap see the checkout
export HOME="$T/home"; mkdir -p "$HOME/Downloads" "$T/bin"; cd "$T" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
FAIL=0; pass() { echo "OK:   $1"; }; fail() { echo "FAIL: $1"; FAIL=1; }
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"
_uora_env_init
newrd() { local r; r="$(_uora_new_run)"; TAG="${r%%$'\t'*}"; RD="${r#*$'\t'}"; printf 'go' > "$RD/instructions.txt"; }
# alive <pid>: running, not a zombie. A KILLed orphan stays a zombie under a Linux subreaper until it is reaped, and kill -0 succeeds on one.
alive() { kill -0 "$1" 2>/dev/null && case "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" in Z*|"") false ;; *) true ;; esac; }
mk() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }

# argv and env: the fake records both
# shellcheck disable=SC2016
mk rec 'printf "%s\n" "$@" > "$HOME/argv"; env > "$HOME/env"; printf "{\"type\":\"result\"}\n"'
newrd; CLAUDE_CODE_SAFE_MODE=1 CLAUDECODE=1 BASH_ENV=/x DYLD_INSERT_LIBRARIES=/x _uora_launch "$RD" "$T/bin/rec" /usr/bin:/bin $(( $(date +%s) + 60 )); rc=$?
[ "$rc" = 0 ] && pass "child ran" || fail "child rc=$rc"
for a in -p --chrome --model sonnet --permission-mode default --setting-sources '' --strict-mcp-config --no-session-persistence \
         --output-format stream-json --verbose "ToolSearch,Read(/$RD/uora-$TAG.txt)" "Read,ToolSearch" "$RD/child-settings.json" go; do
  grep -qxF -- "$a" "$HOME/argv" || fail "argv lacks '$a'"
done
[ "$(tail -1 "$HOME/argv")" = go ] && pass "the positional prompt is last" || fail "prompt position"
for v in CLAUDE_CODE_SAFE_MODE CLAUDECODE BASH_ENV SHELLOPTS ENV CLAUDE_CODE_SIMPLE DYLD_INSERT_LIBRARIES; do
  grep -q "^$v=" "$HOME/env" && fail "$v reached the child" || pass "$v dropped (env -i allowlist)"
done
# bash itself adds PWD, SHLVL, OLDPWD and _ to the fake's environment; everything else came from env -i.
[ "$(cut -d= -f1 "$HOME/env" | grep -vE '^(PWD|SHLVL|OLDPWD|_)$' | sort | tr '\n' ' ')" = "HOME LANG LOGNAME PATH TMPDIR USER " ] \
  && pass "the child env is exactly the six variables" || fail "child env: $(cut -d= -f1 "$HOME/env" | tr '\n' ' ')"
[ "$(cat "$RD/stream.jsonl")" = '{"type":"result"}' ] && pass "stream captured" || fail "stream"

# own process group; group KILL after a natural exit reaps a lingering hook; the publisher survives
# shellcheck disable=SC2016
mk linger 'sleep 30 & echo "$!" > "$HOME/hookpid"; exit 0'
newrd; _uora_launch "$RD" "$T/bin/linger" /usr/bin:/bin $(( $(date +%s) + 60 ))
sleep 0.5; alive "$(cat "$HOME/hookpid")" && fail "a hook descendant outlived the group KILL" || pass "group KILL after exit 0"
kill -0 $$ && pass "the publisher is not in the child's group" || fail "publisher killed"
case "$-" in *m*) fail "monitor mode leaked into the caller's shell" ;; *) pass "caller shell has monitor mode off" ;; esac

# under a caller's set -e: the child's own status comes back and the group KILL still runs
# shellcheck disable=SC2016
mk linger3 'sleep 30 & echo "$!" > "$HOME/hookpid"; exit 3'
newrd; ( set -e; _uora_launch "$RD" "$T/bin/linger3" /usr/bin:/bin $(( $(date +%s) + 60 )); echo "rc=0" ) > "$T/e3" 2>&1; rc=$?
sleep 0.5; [ "$rc" = 3 ] && ! alive "$(cat "$HOME/hookpid")" && pass "set -e caller: exit 3 returned, hook reaped" \
  || fail "set -e caller: rc=$rc hook alive=$(alive "$(cat "$HOME/hookpid")" && echo y || echo n)"
newrd; ( set -e; _uora_launch "$RD" "$T/bin/rec" /usr/bin:/bin $(( $(date +%s) + 60 )) ); rc=$?
[ "$rc" = 0 ] && pass "set -e caller: a clean exit is rc 0 despite the group being gone" || fail "set -e caller: clean exit rc=$rc"

# cutoff: TERM then KILL the whole group, record it, return promptly
mk stubborn 'trap "" TERM; sleep 60 & wait; sleep 60'
newrd; s=$SECONDS; _uora_launch "$RD" "$T/bin/stubborn" /usr/bin:/bin $(( $(date +%s) + 2 ))
[ -f "$RD/cutoff" ] && pass "cutoff recorded" || fail "no cutoff marker"
[ $((SECONDS - s)) -le 12 ] && pass "a TERM-ignoring child is KILLed within 5 s of the cutoff" || fail "cutoff took $((SECONDS - s)) s"
pgrep -f "$T/bin/stubborn" >/dev/null && fail "stubborn child survived" || pass "group gone"

# an unreadable clock is the cutoff, never an unbounded child
mk sleeper 'sleep 60'
newrd; s=$SECONDS; ( _uora_now() { return 1; }; _uora_launch "$RD" "$T/bin/sleeper" /usr/bin:/bin 99999999999 )
[ -f "$RD/cutoff" ] && [ $((SECONDS - s)) -le 10 ] && pass "a failed clock read stops the child at once" || fail "bad clock: cutoff=$([ -f "$RD/cutoff" ] && echo y || echo n) in $((SECONDS - s)) s"
pgrep -f "$T/bin/sleeper" >/dev/null && fail "sleeper survived a bad clock" || pass "bad clock: group gone"

# a cancel that lands before child.pid is written: the core's marker is already there when the
# launcher checks it, so the launcher kills its own group at once
newrd; : > "$RD/cancel"; s=$SECONDS; _uora_launch "$RD" "$T/bin/sleeper" /usr/bin:/bin $(( $(date +%s) + 60 ))
[ $((SECONDS - s)) -le 5 ] && [ ! -f "$RD/cutoff" ] && pass "a cancel marker kills the child as soon as its pid is recorded" \
  || fail "cancel marker: took $((SECONDS - s)) s, cutoff=$([ -f "$RD/cutoff" ] && echo y || echo n)"
pgrep -f "$T/bin/sleeper" >/dev/null && fail "sleeper survived a cancel" || pass "cancel: group gone"

# cleanup: only record.json survives; this tag's downloads go, symlinks are never followed
newrd; for f in uora-$TAG.txt stream.jsonl decisions.jsonl guard.json.done guard-state.json phase child-settings.json; do : > "$RD/$f"; done
mkdir "$RD/oob"; : > "$RD/oob/l.x"; printf '{}' > "$RD/record.json"
: > "$HOME/Downloads/uora-$TAG.json"; : > "$HOME/Downloads/uora-$TAG (1).json"; : > "$HOME/Downloads/uora-$TAG.json.crdownload"
: > "$T/victim"; ln -s "$T/victim" "$HOME/Downloads/uora-$TAG (2).json"
: > "$HOME/Downloads/uora-ffffffffffffffff.json"
_uora_cleanup "$RD" "$TAG"
[ "$(ls -A "$RD")" = record.json ] && pass "run dir holds only record.json" || fail "left: $(ls -A "$RD" | tr '\n' ' ')"
[ ! -e "$HOME/Downloads/uora-$TAG.json" ] && [ ! -e "$HOME/Downloads/uora-$TAG (1).json" ] && [ ! -e "$HOME/Downloads/uora-$TAG.json.crdownload" ] \
  && pass "own downloads removed" || fail "own downloads left"
[ -e "$T/victim" ] && [ -L "$HOME/Downloads/uora-$TAG (2).json" ] && pass "a symlink is never followed or removed" || fail "symlink handling"
[ -e "$HOME/Downloads/uora-ffffffffffffffff.json" ] && pass "another run's download untouched" || fail "foreign download removed"

# sweep: old run dirs and old stray answers go; fresh ones and non-matching names stay
old="$(_uora_base)/run-0000000000000001"; mkdir -p "$old"; touch -t 202001010000 "$old"
fresh="$(_uora_base)/run-0000000000000002"; mkdir -p "$fresh"
: > "$HOME/Downloads/uora-0000000000000003.json.crdownload"; touch -t 202001010000 "$HOME/Downloads/uora-0000000000000003.json.crdownload"
: > "$HOME/Downloads/uora-notatag.json"; touch -t 202001010000 "$HOME/Downloads/uora-notatag.json"
mkdir -p "$HOME/Library/Application Support/Google/Chrome/Profile 2" "$T/custom"
printf '{"download":{"default_directory":"%s"}}' "$T/custom" > "$HOME/Library/Application Support/Google/Chrome/Profile 2/Preferences"
: > "$T/custom/uora-0000000000000004 (1).json"; touch -t 202001010000 "$T/custom/uora-0000000000000004 (1).json"
_uora_sweep 3600
[ ! -e "$old" ] && [ -d "$fresh" ] && pass "sweep: old run dir gone, fresh kept" || fail "sweep run dirs"
[ ! -e "$HOME/Downloads/uora-0000000000000003.json.crdownload" ] && pass "sweep: interrupted .crdownload removed" || fail "crdownload kept"
[ -e "$HOME/Downloads/uora-notatag.json" ] && pass "sweep: a non-tag name is kept" || fail "sweep removed a foreign name"
[ ! -e "$T/custom/uora-0000000000000004 (1).json" ] && pass "sweep: a non-default profile's custom dir is a candidate" || fail "custom dir not swept"

# under a caller's set -e: a malformed profile never truncates the dir list, and a missing run
# base never skips the download sweep
mkdir -p "$HOME/Library/Application Support/Google/Chrome/Default"
printf '{not json' > "$HOME/Library/Application Support/Google/Chrome/Default/Preferences"
# (run on its own line: inside an && / || list bash ignores errexit, so the probe would prove nothing)
( set -e; _uora_dl_dirs ) > "$T/dl" 2>/dev/null
grep -qxF "$HOME/Downloads" "$T/dl" && pass "set -e: a malformed Preferences still lists ~/Downloads" || fail "set -e: dl_dirs truncated"
rm -rf "$(_uora_base)"; : > "$HOME/Downloads/uora-0000000000000005.json"; touch -t 202001010000 "$HOME/Downloads/uora-0000000000000005.json"
( set -e; _uora_sweep 3600 ); [ ! -e "$HOME/Downloads/uora-0000000000000005.json" ] && pass "set -e: sweep runs with no run base yet" || fail "set -e: sweep stopped early"

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-launch" || exit 1
