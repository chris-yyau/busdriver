#!/bin/bash
# tests/test-ultra-oracle-lifecycle.sh — spec §2 seams and reopen, §3 probe and launch environment.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Canonical: the resolver prints /private/var, not the /var symlink mktemp returns on macOS.
T="$(mktemp -d)" && [ -n "$T" ] && T="$(cd "$T" && pwd -P)" && [ -n "$T" ] || { echo "FAIL: mktemp"; exit 1; }   # never let the rm -rf trap see the checkout
export HOME="$T/home"; mkdir -p "$HOME" "$T/bin"; cd "$T" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
FAIL=0; pass() { echo "OK:   $1"; }; fail() { echo "FAIL: $1"; FAIL=1; }
export _ULTRA_ORACLE_PLATFORM=Hacked _ULTRA_ORACLE_CLAUDE_BIN=/tmp/evil   # exported values must change nothing
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"
[ "$_ULTRA_ORACLE_PLATFORM" = "$(uname -s)" ] && pass "an exported _ULTRA_ORACLE_PLATFORM changes nothing" || fail "platform taken from env"
[ -z "$_ULTRA_ORACLE_CLAUDE_BIN" ] && pass "an exported _ULTRA_ORACLE_CLAUDE_BIN changes nothing" || fail "claude bin taken from env"
[ "${_ULTRA_ORACLE_OPEN_CMD[*]}" = "open -a Google Chrome" ] && pass "default open command" || fail "open cmd"
unset _ULTRA_ORACLE_PLATFORM _ULTRA_ORACLE_CLAUDE_BIN

# probe: a fake claude whose --help lacks a flag, hangs, or has both flags
mk() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
_uora_env_init
# shellcheck disable=SC2016  # the fake claude bodies expand at their own runtime
{
mk ok   'case "$1" in --version) echo "2.1.317 (Claude Code)" ;; *) printf "  --chrome\n  --setting-sources <s>\n" ;; esac'
mk old  'printf "  --setting-sources <s>\n"'
mk hang 'sleep 60'
mk oldver 'case "$1" in --version) echo "2.1.200 (Claude Code)" ;; *) printf "  --chrome\n  --setting-sources <s>\n" ;; esac'
mk nover  'case "$1" in --version) echo "dev build" ;; *) printf "  --chrome\n  --setting-sources <s>\n" ;; esac'
}
# r3 version gate, both signatures outcomes, through the in-process _UORA_CHILD_DIR seam
cp -R "$DIR/scripts/hooks/ultra-oracle-child" "$T/child"; _UORA_CHILD_DIR_SAVE="$_UORA_CHILD_DIR"; _UORA_CHILD_DIR="$T/child"
/usr/bin/jq '.claude_min_version = null' "$DIR/scripts/hooks/ultra-oracle-child/signatures.json" > "$T/child/signatures.json"
_uora_probe "$T/bin/nover" /usr/bin:/bin && pass "probe: no minimum -> version not read" || fail "probe read the version with no minimum"
/usr/bin/jq '.claude_min_version = "2.1.295"' "$DIR/scripts/hooks/ultra-oracle-child/signatures.json" > "$T/child/signatures.json"
_uora_probe "$T/bin/ok" /usr/bin:/bin && pass "probe: 2.1.317 >= 2.1.295" || fail "probe refused a new enough claude"
_uora_probe "$T/bin/oldver" /usr/bin:/bin && fail "probe accepted 2.1.200 < 2.1.295" || pass "probe: old claude -> unavailable"
_uora_probe "$T/bin/nover" /usr/bin:/bin && fail "probe accepted an unparseable version" || pass "probe: unparseable version -> unavailable"
_UORA_CHILD_DIR="$_UORA_CHILD_DIR_SAVE"
_uora_ver_ge 2.10.0 2.9.9 && _uora_ver_ge 2.1.295 2.1.295 && ! _uora_ver_ge 2.1.29 2.1.295 && ! _uora_ver_ge 1.x.0 1.0.0 \
  && pass "_uora_ver_ge is numeric per field and fails closed" || fail "_uora_ver_ge"
_uora_probe "$T/bin/ok" /usr/bin:/bin && pass "probe: both flags" || fail "probe ok"
_uora_probe "$T/bin/old" /usr/bin:/bin && fail "probe accepted a claude without --chrome" || pass "probe: missing flag -> unavailable"
s=$SECONDS; _uora_probe "$T/bin/hang" /usr/bin:/bin && fail "hanging --help accepted" || pass "probe: hanging --help -> unavailable"
[ $((SECONDS - s)) -le 20 ] && pass "probe bounded at 15 s" || fail "probe took $((SECONDS - s)) s"
# the probe runs under the env -i allowlist: a caller's CLAUDE_CODE_SAFE_MODE / PATH shim never reaches it
# shellcheck disable=SC2016
mk envdump 'env > "$HOME/probe-env"; case "$1" in --version) echo 2.1.317 ;; *) printf -- "--chrome --setting-sources" ;; esac'
CLAUDE_CODE_SAFE_MODE=1 SHELLOPTS_X=1 _uora_probe "$T/bin/envdump" /usr/bin:/bin
[ -s "$HOME/probe-env" ] || fail "the env-dump probe never ran"
grep -q CLAUDE_CODE_SAFE_MODE "$HOME/probe-env" && fail "caller env leaked into the probe" || pass "probe env is the allowlist"
# timeout and env themselves run with no loader variable (env -i only cleans the child). A stand-in
# _portable_timeout records its own environment, then runs the command.
eval "_orig_$(declare -f _portable_timeout)"
_portable_timeout() { env > "$HOME/pt-env"; shift; "$@"; }
LD_AUDIT=x LD_LIBRARY_PATH=x DYLD_LIBRARY_PATH=x DYLD_FRAMEWORK_PATH=x _uora_probe "$T/bin/ok" /usr/bin:/bin >/dev/null
[ -s "$HOME/pt-env" ] || fail "the stand-in timeout never ran"
grep -qE '^(LD_|DYLD_)' "$HOME/pt-env" && fail "a loader variable reached timeout/env: $(grep -E '^(LD_|DYLD_)' "$HOME/pt-env" | head -1)" \
  || pass "probe: no loader variable reaches timeout or env"
# reopen: timeout -k reports 137 when it had to KILL; that is still the budget running out
_portable_timeout() { return 137; }
_uora_reopen $(( $(date +%s) + 30 )); [ $? = 124 ] && pass "reopen: a KILLed open (137) -> timeout" || fail "reopen: 137 not read as timeout"
eval "$(declare -f _orig__portable_timeout | sed '1s/^_orig__portable_timeout/_portable_timeout/')"

# resolve: the seam wins only when absolute
_ULTRA_ORACLE_CLAUDE_BIN=relative; _uora_resolve_claude >/dev/null && fail "relative claude accepted" || pass "non-absolute claude -> unavailable"
_ULTRA_ORACLE_CLAUDE_BIN="$T/bin/ok"; [ "$(_uora_resolve_claude)" = "$T/bin/ok"$'\t'"/usr/bin:/bin" ] && pass "seam resolves" || fail "seam"
_ULTRA_ORACLE_CLAUDE_BIN=""
cp "$T/bin/ok" "$T/bin/claude"
# The resolver refuses a binary outside any git repo or inside the caller's checkout, so it runs
# from a throwaway repo that does not contain $T/bin (as Task 11 does for out-of-process suites).
mkdir -p "$T/repo" && git -C "$T/repo" init -q
r="$(cd "$T/repo" && PATH="$T/bin:/usr/bin:/bin" _uora_resolve_claude)" && [ "${r%%$'\t'*}" = "$T/bin/claude" ] \
  && pass "the trusted resolver finds a claude on PATH outside the repo" || fail "resolver: '$r'"

# reopen: once, bounded by the cutoff, failure -> extension-not-connected, hang -> timeout
# shellcheck disable=SC2016
mk opencount 'echo x >> "$HOME/opens"'
_ULTRA_ORACLE_OPEN_CMD=("$T/bin/opencount")
_uora_reopen $(( $(date +%s) + 30 )); rc=$?
[ "$rc" = 0 ] && [ "$(wc -l < "$HOME/opens" | tr -dc 0-9)" = 1 ] && pass "reopen runs the open command once" || fail "reopen rc=$rc"
_ULTRA_ORACLE_OPEN_CMD=(/usr/bin/false); _uora_reopen $(( $(date +%s) + 30 )); [ $? = 1 ] && pass "failing open -> extension-not-connected" || fail "failing open"
_ULTRA_ORACLE_OPEN_CMD=("$T/bin/hang"); s=$SECONDS; _uora_reopen $(( $(date +%s) + 3 )); rc=$?
[ "$rc" = 124 ] && [ $((SECONDS - s)) -le 8 ] && pass "hanging open -> timeout within the cutoff" || fail "hanging open rc=$rc in $((SECONDS - s)) s"
_uora_reopen $(( $(date +%s) - 1 )); [ $? = 124 ] && pass "no time left -> timeout without running open" || fail "past cutoff"
want="$(/usr/bin/jq -r .reopen_settle_seconds "$DIR/scripts/hooks/ultra-oracle-child/signatures.json")"
[ "$want" = "$(/usr/bin/jq -r .r4.settle_s "$DIR/tests/fixtures/ultra-oracle/qualification.json")" ] \
  && pass "the reopen settle ($want s) is pinned to the r4 measurement" || fail "settle drifted from r4"
# the settle sleep never runs past the cutoff: settle 30 with 2 s left -> 124 within ~2 s
cp -R "$DIR/scripts/hooks/ultra-oracle-child" "$T/child2"; _UORA_CHILD_DIR_SAVE="$_UORA_CHILD_DIR"; _UORA_CHILD_DIR="$T/child2"
/usr/bin/jq '.reopen_settle_seconds = 30' "$DIR/scripts/hooks/ultra-oracle-child/signatures.json" > "$T/child2/signatures.json"
_ULTRA_ORACLE_OPEN_CMD=("$T/bin/opencount"); s=$SECONDS; _uora_reopen $(( $(date +%s) + 2 )); rc=$?
[ "$rc" = 124 ] && [ $((SECONDS - s)) -le 4 ] && pass "a settle longer than the time left stops at the cutoff -> timeout" \
  || fail "settle overran: rc=$rc in $((SECONDS - s)) s"
# signatures.json: explicit null vs unreadable vs malformed
/usr/bin/jq '.pretool_on_failure = null | .claude_min_version = null' "$DIR/scripts/hooks/ultra-oracle-child/signatures.json" > "$T/child2/signatures.json"
v="$(_uora_sig pretool_on_failure)"; rc=$?; [ "$rc" = 0 ] && [ -z "$v" ] && pass "_uora_sig: explicit null -> rc 0, empty" || fail "sig null rc=$rc"
_uora_sig_ok && pass "_uora_sig_ok accepts both r3 keys null" || fail "sig_ok null pair"
/usr/bin/jq 'del(.claude_min_version)' "$DIR/scripts/hooks/ultra-oracle-child/signatures.json" > "$T/child2/signatures.json"
_uora_sig claude_min_version >/dev/null && fail "_uora_sig: an absent key read as null" || pass "_uora_sig: absent key -> rc 1"
_uora_sig_ok && fail "_uora_sig_ok accepted a missing key" || pass "_uora_sig_ok: missing key -> refused"
/usr/bin/jq '.pretool_on_failure = "block" | .claude_min_version = null' "$DIR/scripts/hooks/ultra-oracle-child/signatures.json" > "$T/child2/signatures.json"
_uora_sig_ok && fail "_uora_sig_ok accepted onFailure without a minimum version" || pass "_uora_sig_ok: r3 keys must pair"
printf '{not json' > "$T/child2/signatures.json"
_uora_sig pretool_on_failure >/dev/null && fail "_uora_sig read malformed JSON" || pass "_uora_sig: malformed -> rc 1"
_uora_sig_ok && fail "_uora_sig_ok accepted malformed JSON" || pass "_uora_sig_ok: malformed -> refused"
_uora_probe "$T/bin/ok" /usr/bin:/bin && fail "probe passed with unreadable signatures" || pass "probe: unreadable signatures -> unavailable, never skip the version gate"
rm -f "$T/child2/signatures.json"
_uora_sig_ok && fail "_uora_sig_ok accepted a missing file" || pass "_uora_sig_ok: missing file -> refused"
_UORA_CHILD_DIR="$_UORA_CHILD_DIR_SAVE"
_uora_sig_ok && pass "the committed signatures.json validates" || fail "committed signatures.json is malformed"

# a clock that fails or prints garbage is rc 1 from _uora_now, and reopen then runs nothing
mkdir -p "$T/badclock"; printf '#!/bin/bash\necho garbage\n' > "$T/badclock/date"; chmod +x "$T/badclock/date"
( PATH="$T/badclock:/usr/bin:/bin"; _uora_now >/dev/null ) && fail "_uora_now accepted a non-numeric clock" || pass "_uora_now: non-numeric clock -> rc 1"
: > "$HOME/opens"; _ULTRA_ORACLE_OPEN_CMD=("$T/bin/opencount")
( PATH="$T/badclock:/usr/bin:/bin"; _uora_reopen 99999999999 ); rc=$?
[ "$rc" = 1 ] && [ ! -s "$HOME/opens" ] && pass "reopen: unreadable clock -> rc 1, open never runs" || fail "reopen with a bad clock rc=$rc"

# fake clock: _uora_now is the only clock the lifecycle reads
_uora_now() { echo 1000; }; [ "$(_uora_now)" = 1000 ] && pass "clock seam" || fail "clock seam"

[ "$FAIL" = 0 ] && echo "PASS test-ultra-oracle-lifecycle" || exit 1
