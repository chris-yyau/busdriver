#!/usr/bin/env bash
# tests/test-agy-argv-limit.sh — regression coverage for the agy argv size guard.
#
# WHY: the guard is portability-sensitive (Linux-only MAX_ARG_STRLEN vs ARG_MAX)
# and byte-vs-character sensitive. Both are silent-failure modes: a wrong limit
# either rejects valid prompts or lets an E2BIG through, and an E2BIG surfaces as
# "Output was not valid JSON" — the exact silent degrade this guard exists to stop.
set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/resolve-cli.sh" 2>/dev/null

FAILED=0
fail() { echo "FAIL: $*"; FAILED=1; }

# ── byte vs character length (multibyte locale correctness) ──────────────
# ${#var} counts CHARACTERS; the kernel limits BYTES. A CJK prompt reports 1/3
# the byte count, so a ${#var}-based guard would pass a 3x-oversize prompt.
# Brace expansion (not $(seq …)) so there is no unquoted word-splitting to lint.
cjk=$(printf '%.0s中' {1..100})
got=$(_agy_bytelen "$cjk")
[[ "$got" = "300" ]] || fail "t1: _agy_bytelen on 100 CJK chars = $got, expected 300 bytes"

ascii=$(printf '%.0sa' {1..50})
got=$(_agy_bytelen "$ascii")
[[ "$got" = "50" ]] || fail "t2: _agy_bytelen on 50 ASCII chars = $got, expected 50"

# Empty and unset must not error or return garbage.
got=$(_agy_bytelen "")
[[ "$got" = "0" ]] || fail "t3: _agy_bytelen on empty string = $got, expected 0"

# ── limit selection ──────────────────────────────────────────────────────
limit=$(_agy_argv_limit)
case "$limit" in
    ''|*[!0-9]*) fail "t4: _agy_argv_limit returned non-numeric '$limit'" ;;
esac
[[ "${limit:-0}" -gt 0 ]] || fail "t5: _agy_argv_limit returned non-positive '$limit'"

# On Linux the per-argument MAX_ARG_STRLEN (131071) binds whenever it is lower
# than ARG_MAX/2. On macOS/BSD no per-arg cap exists, so ARG_MAX/2 stands and the
# limit must NOT be clamped to the Linux figure.
_uname=$(uname -s 2>/dev/null) || _uname=""
if [[ "$_uname" == "Linux" ]]; then
    [[ "$limit" -le 131071 ]] || fail "t6: Linux limit $limit exceeds MAX_ARG_STRLEN 131071"
else
    [[ "$limit" -ne 131071 ]] || fail "t6: non-Linux limit was clamped to the Linux-only 131071"
fi

# ── boundary behavior ────────────────────────────────────────────────────
_agy_prompt_oversize "$limit" && fail "t7: size exactly at the limit must NOT be oversize"
_agy_prompt_oversize "$(( limit + 1 ))" || fail "t8: size limit+1 must be oversize"
_agy_prompt_oversize 0 && fail "t9: zero-size must not be oversize"

# A real blueprint prompt (~40-100 KB) must pass on every platform, or design
# review silently loses its agy lens again.
_agy_prompt_oversize 100000 && fail "t10: a realistic 100 KB review prompt was rejected"


# ── transport decision: _agy_wants_argv_prompt ───────────────────────────
# The core of this change. Size tests can all pass while the transport decision
# is wrong, which would silently restore the /dev/stdin bug — so cover 1.0.x,
# >=1.1, unknown/timeout, caching, and env-override rejection explicitly.
_probe_with() {  # $1 = script body for a fake `agy` on PATH; echoes argv|stdin
    local d; d=$(mktemp -d) || return 1
    printf '#!/bin/sh\n%s\n' "$1" > "$d/agy"
    chmod +x "$d/agy"
    if PATH="$d:$PATH" bash -c '. "'"$REPO_ROOT"'/scripts/lib/resolve-cli.sh" 2>/dev/null; _agy_wants_argv_prompt'; then
        printf 'argv'
    else
        printf 'stdin'
    fi
    rm -rf "$d"
}

# t19: agy 1.0.x resolves --print as a PATH → must keep the stdin form
[[ "$(_probe_with 'printf "1.0.0\n"')" == "stdin" ]] \
    || fail "t19: agy 1.0.0 must use the stdin transport, not argv"

# t20: agy 1.1.x sends --print's value verbatim → must use argv
[[ "$(_probe_with 'printf "1.1.4\n"')" == "argv" ]] \
    || fail "t20: agy 1.1.4 must use the argv transport"

# t21: a future major must use argv (guards a naive major==1 comparison)
[[ "$(_probe_with 'printf "2.0.0\n"')" == "argv" ]] \
    || fail "t21: agy 2.0.0 must use the argv transport"

# t22: unparseable version → assume modern. Guessing "old" would reintroduce the
# /dev/stdin bug on a working install, which is the worse failure direction.
[[ "$(_probe_with 'printf "weird-build\n"')" == "argv" ]] \
    || fail "t22: unparseable version must assume modern (argv)"

# t23: a hanging `agy --version` must not hang the caller — the probe is wrapped
# in _portable_timeout 5, and a timeout falls through to modern.
_t0=$(date +%s)
_hang=$(_probe_with 'sleep 30')
_elapsed=$(( $(date +%s) - _t0 ))
[[ "$_hang" == "argv" ]] || fail "t23: a hanging probe must fall through to argv"
[[ "$_elapsed" -lt 20 ]] || fail "t23: probe was not bounded (took ${_elapsed}s; expected <20)"

# t24: env must not preselect the transport — a committed settings.json `env`
# block could otherwise pin it and break delivery (#325 / ADR 0016).
_envforced=$(mktemp -d)
printf '#!/bin/sh\nprintf "1.0.0\\n"\n' > "$_envforced/agy"; chmod +x "$_envforced/agy"
if PATH="$_envforced:$PATH" _AGY_ARGV_PROMPT=1 bash -c '. "'"$REPO_ROOT"'/scripts/lib/resolve-cli.sh" 2>/dev/null; _agy_wants_argv_prompt'; then
    fail "t24: inherited _AGY_ARGV_PROMPT=1 overrode a 1.0.x probe (env must not preselect transport)"
fi
rm -rf "$_envforced"

# t25: the decision is cached — one probe per process, not one per call.
_cachedir=$(mktemp -d)
_cnt="$_cachedir/n"; printf '0' > "$_cnt"
# shellcheck disable=SC2016  # stub body must expand in the STUB, not here
printf '#!/bin/sh\nn=$(cat "%s"); printf "%%s" "$((n+1))" > "%s"; printf "1.1.4\\n"\n' "$_cnt" "$_cnt" > "$_cachedir/agy"
chmod +x "$_cachedir/agy"
PATH="$_cachedir:$PATH" bash -c '. "'"$REPO_ROOT"'/scripts/lib/resolve-cli.sh" 2>/dev/null
_agy_wants_argv_prompt; _agy_wants_argv_prompt; _agy_wants_argv_prompt' >/dev/null 2>&1
_probes=$(cat "$_cnt")
[[ "$_probes" == "1" ]] || fail "t25: expected 1 cached probe across 3 calls, got $_probes"
rm -rf "$_cachedir"

# ── stdin transport: no SIGPIPE on argv mode, stdin still fed on 1.0.x ────
# _run_review_with_retries pipes the prompt into the child. A CLI that takes the
# prompt via ARGV never drains fd 0, so under pipefail the writer dies of SIGPIPE
# the moment the child exits and the substitution returns 141 WITH a valid review
# attached — callers read that as failure and silently degrade to droid.
# Only fires above the ~64 KB pipe buffer, i.e. exactly at real review-prompt
# sizes, so a small-prompt test would miss it entirely. Both directions covered:
# argv must NOT be piped, 1.0.x MUST still be.
_transport_probe() {   # $1=version $2=prompt bytes; echoes "<rc> <out>"
    local d rc out
    d=$(mktemp -d) || return 1
    cat > "$d/agy" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then printf '%s\n' "$FAKE_AGY_VER"; exit 0; fi
prev=""; tgt=""
for a in "$@"; do
  if [ "$prev" = "--print" ]; then tgt="$a"; fi
  prev="$a"
done
if [ "$tgt" = "/dev/stdin" ]; then
  printf 'STDIN_BYTES=%s\n' "$(cat | wc -c | tr -d ' ')"
else
  printf 'ARGV_MODE\n'
fi
STUB
    chmod +x "$d/agy"
    # The prompt is generated INSIDE the subshell, never passed as an argv element
    # to `bash -c`. Passing it as an argument would hit Linux's MAX_ARG_STRLEN
    # (131071 B) — the very ceiling this suite exists to test — so `bash` would
    # fail before either transport ran, and the test would be green on macOS
    # (no per-arg cap) while broken on the Linux CI runner.
    out=$(PATH="$d:$PATH" FAKE_AGY_VER="$1" PROMPT_BYTES="$2" bash -c '
        set -uo pipefail
        . "'"$REPO_ROOT"'/scripts/lib/resolve-cli.sh" 2>/dev/null
        p=$(head -c "$PROMPT_BYTES" /dev/zero | tr "\0" "a")
        execute_review agy "$p" 10 2>&1')
    rc=$?
    rm -rf "$d"
    printf '%s %s' "$rc" "$(printf '%s' "$out" | head -c 40)"
}

# Prompt size for the transport probes. Must sit ABOVE the ~64 KB pipe buffer
# (below it, SIGPIPE never fires and the regression is invisible) and BELOW
# Linux's 131071 B MAX_ARG_STRLEN (above it, argv delivery is correctly refused
# by _agy_prompt_oversize and the transport is never exercised). 100 KB is inside
# both bounds on every platform and matches real review-prompt sizes.
_TRANSPORT_BYTES=100000

# t26: argv mode + a prompt well over the pipe buffer must NOT return 141.
_r=$(_transport_probe 1.1.4 "$_TRANSPORT_BYTES")
[[ "${_r%% *}" == "0" ]]     || fail "t26: argv mode on a 100KB prompt returned rc=${_r%% *} (141 = SIGPIPE regression)"
[[ "$_r" == *"ARGV_MODE"* ]]     || fail "t26: expected argv transport on 1.1.4, got [${_r#* }]"

# t27: 1.0.x must STILL be fed on stdin — the SIGPIPE fix must not starve it.
_r=$(_transport_probe 1.0.0 "$_TRANSPORT_BYTES")
[[ "${_r%% *}" == "0" ]] || fail "t27: 1.0.x transport returned rc=${_r%% *}"
[[ "$_r" == *"STDIN_BYTES=$_TRANSPORT_BYTES"* ]]     || fail "t27: 1.0.x must receive the full prompt on stdin, got [${_r#* }]"

# ── permission posture: skip-permissions is opt-in per caller (#424) ─────────
# The agy reviewer runs headless (`--print`) and cannot prompt for tool
# permission, so WITHOUT --dangerously-skip-permissions every read_file/command
# request auto-denies and the slot dies ("no output produced"), dropping
# blueprint coverage below FULL. But execute_review is SHARED (litmus reviews
# arbitrary diffs through it too), and auto-approving tools on untrusted prompt
# content is a read-then-report exfil surface --sandbox does not close. So the
# flag is gated on BUSDRIVER_AGY_REVIEW_SKIP_PERMS=1, set only by blueprint-review
# (operator-authored docs). Invariants: --sandbox ALWAYS; skip-permissions ONLY
# when the opt-in is set; never skip-permissions without --sandbox (containment).
_flags_probe() {   # $1=version, $2=opt-in value (unset if empty); echoes agy argv
    local d out
    d=$(mktemp -d) || return 1
    cat > "$d/agy" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then printf '%s\n' "$FAKE_AGY_VER"; exit 0; fi
printf 'ARGV:%s\n' "$*"
STUB
    chmod +x "$d/agy"
    out=$(PATH="$d:$PATH" FAKE_AGY_VER="$1" _OPTIN="${2-}" bash -c '
        set -uo pipefail
        [ -n "$_OPTIN" ] && export BUSDRIVER_AGY_REVIEW_SKIP_PERMS="$_OPTIN"
        . "'"$REPO_ROOT"'/scripts/lib/resolve-cli.sh" 2>/dev/null
        execute_review agy "review this plan" 10 2>&1' | grep '^ARGV:')
    rm -rf "$d"
    printf '%s' "$out"
}

# t28: shared default (opt-in UNSET) — --sandbox present, skip-permissions ABSENT.
# This is the fix's blast-radius guard: litmus-via-agy must NOT auto-approve tools.
for _v in 1.1.4 1.0.0; do
    _fp=$(_flags_probe "$_v" "")
    [[ "$_fp" == *"--sandbox"* ]] \
        || fail "t28: agy $_v default review dropped --sandbox [$_fp]"
    [[ "$_fp" != *"--dangerously-skip-permissions"* ]] \
        || fail "t28: agy $_v default review leaked skip-permissions without opt-in [$_fp]"
done

# t29: opt-in set — BOTH --sandbox and skip-permissions (the #424 blueprint fix).
for _v in 1.1.4 1.0.0; do
    _fp=$(_flags_probe "$_v" "1")
    [[ "$_fp" == *"--sandbox"* ]] \
        || fail "t29: agy $_v opt-in review dropped --sandbox (containment) [$_fp]"
    [[ "$_fp" == *"--dangerously-skip-permissions"* ]] \
        || fail "t29: agy $_v opt-in review dropped skip-permissions (#424 headless auto-deny) [$_fp]"
done

if [[ "$FAILED" -eq 0 ]]; then echo "PASS: test-agy-argv-limit"; else exit 1; fi
