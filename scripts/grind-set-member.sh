#!/usr/bin/env bash
# scripts/grind-set-member.sh - is a blamed commit grind-written?
#
# The consumer half of Rail A (ADR 0036). agents/pr-grinder.md's proportionality
# gate calls this instead of reasoning about GRIND_SET in prose: the strict
# validation rules below are the ones that decide whether the gate fails CLOSED
# or silently degrades back to inert, so they belong in a testable script.
#
#   GRIND_SET = {resolved PRIOR_ATTEMPTS commit= values}   (fail-OPEN: drop unresolvable)
#             u {validated GRIND_SHAS entries}             (STRICT: any violation BAILs)
#
# Usage:
#   grind-set-member.sh -C <repo_dir> [--shas <GRIND_SHAS>] [--status <GRIND_SHAS_STATUS>]
#                       [--head <GRIND_HEAD_SHA>] [--prior <commit=,commit=,...>] <blamed_sha>
#
#   --shas / --status / --head are the three worker context-block fields, passed
#   VERBATIM. Omit ALL THREE flags to model a pre-contract dispatcher. --shas and
#   --status are only ever emitted together, and whenever they are present --head
#   is required to bind the certified set to the HEAD it was derived at. Any
#   partial combination is a contract violation, not a default.
#
# Exit codes:
#   0  the blamed SHA IS in GRIND_SET   (grind-written)
#   1  the blamed SHA is NOT in GRIND_SET (author-written - run the round normally)
#   2  usage error
#   3  CONTRACT VIOLATION - the caller must BAIL env. A dispatcher-certified set
#      that does not validate is a broken contract, not a soft signal. Carrying
#      the inherited fail-OPEN rule here would let a corrupted durable set
#      degrade silently to today's inert gate while STATUS still read "ok".

set -uo pipefail

# Pathname expansion OFF for the whole script. The comma lists below are split
# with an unquoted `set --`, which performs GLOBBING as well as word splitting:
# a malformed token of forty `?` characters would otherwise expand against the
# working directory and could match a filename that happens to be a valid commit
# OID, letting a non-hex token pass strict validation instead of BAILing.
# Nothing here ever wants a glob.
set -f

# -C is this script's repository boundary, and inherited git environment
# variables OVERRIDE it: with GIT_DIR pointing elsewhere, a blamed SHA could be
# resolved against a DIFFERENT repository, turning membership into a coin flip.
# Gate env is repo-injectable here (#325 / ADR 0016), so clear them.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
      GIT_EXEC_PATH GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT \
      GIT_CONFIG_PARAMETERS

# refs/replace entries rewrite what git reports for a commit, so a replacement
# could make a blamed SHA resolve to something other than the commit the
# producer certified. Membership must be decided on real objects.
export GIT_NO_REPLACE_OBJECTS=1

# bash imports environment entries named `BASH_FUNC_<name>%%` as shell
# FUNCTIONS, shadowing the real binaries at every call site. A committed
# settings.json env block can set those (#325 / ADR 0016): a stubbed `git` makes
# every blamed SHA resolve, a stubbed `grep` decides membership outright. Drop
# EVERY inherited function before defining our own or running anything external.
# Parsed with builtins only — using awk or sed here would be the same hole one
# level up.
while read -r _d _flag _name; do
    [ -n "${_name:-}" ] && unset -f "$_name"
done <<< "$(declare -F)"
unset _d _flag _name

# Defense-in-depth, not the boundary: the loop above runs `declare`/`read`/
# `unset` as bare names while inherited functions are still live, so a stubbed
# builtin defeats it, as does BASH_ENV or a hijacked interpreter. That regress
# does not terminate. The boundary is the caller's env sanitization (#325 /
# ADR 0016). Verifying the EFFECT does terminate — this canary proves the `git`
# this process reaches is the real binary, catching inherited function, alias,
# PATH hijack, and defeated cleanup in one call. Here a stubbed `git` would make
# every blamed SHA "resolve" and turn the gate into an unconditional BAIL.
_gv=$(command git --version 2>/dev/null) || _gv=""
case "$_gv" in
    "git version "*) : ;;
    *)
        printf "grind-set-member.sh: CONTRACT VIOLATION: \`git\` does not resolve to the real git binary (shadowed function, alias, or PATH hijack); got %s\n" \
            "${_gv:-no output}" >&2
        exit 3
        ;;
esac
unset _gv

usage_error() {
    printf 'grind-set-member.sh: %s\n' "$1" >&2
    exit 2
}

contract_violation() {
    printf 'grind-set-member.sh: CONTRACT VIOLATION: %s\n' "$1" >&2
    exit 3
}

REPO_DIR=""
SHAS=""
STATUS=""
PRIOR=""
HEAD_AT_SCAN=""
HAVE_SHAS=0
HAVE_STATUS=0
HAVE_HEAD=0

while [ $# -gt 0 ]; do
    case "$1" in
        -C)       [ $# -ge 2 ] || usage_error "-C requires a directory argument"
                  REPO_DIR="$2"; shift 2 ;;
        --shas)   [ $# -ge 2 ] || usage_error "--shas requires a value"
                  SHAS="$2"; HAVE_SHAS=1; shift 2 ;;
        --status) [ $# -ge 2 ] || usage_error "--status requires a value"
                  STATUS="$2"; HAVE_STATUS=1; shift 2 ;;
        --prior)  [ $# -ge 2 ] || usage_error "--prior requires a value"
                  PRIOR="$2"; shift 2 ;;
        --head)   [ $# -ge 2 ] || usage_error "--head requires a value"
                  HEAD_AT_SCAN="$2"; HAVE_HEAD=1; shift 2 ;;
        --)       shift; break ;;
        -*)       usage_error "unknown option: $1" ;;
        *)        break ;;
    esac
done

[ $# -eq 1 ] || usage_error \
    "usage: grind-set-member.sh -C <repo_dir> [--shas S] [--status S] [--head H] [--prior P] <blamed_sha>"

BLAMED="$1"
[ -n "$REPO_DIR" ] || usage_error "-C <repo_dir> is required"
[ -d "$REPO_DIR" ] || usage_error "-C: not a directory: $REPO_DIR"

command git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 \
    || contract_violation "not a git repository: $REPO_DIR"

# OID width comes from THIS repository's object format, not a hardcoded 40 or a
# 40-or-64 alternation: in a SHA-256 repo a 40-character value is an
# abbreviation that rev-parse resolves happily.
case "$(command git -C "$REPO_DIR" rev-parse --show-object-format 2>/dev/null)" in
    sha1)   _oid_len=40 ;;
    sha256) _oid_len=64 ;;
    *)      contract_violation "cannot determine the repository's object format" ;;
esac

# --- The blamed SHA -----------------------------------------------------------
# git blame --porcelain's first line is "<sha> <orig-line> <final-line> [count]",
# not a bare SHA. Callers extract field 1; accept either shape here so a caller
# that forwards the whole line still gets a correct answer instead of a
# guaranteed non-match and a permanently inert gate.
BLAMED=${BLAMED%%[[:space:]]*}
[ -n "$BLAMED" ] || usage_error "blamed SHA is empty"

# Resolving the blamed SHA is DEFERRED until after the contract fields are
# validated below. The all-zero marker exits 1 ("author-written"), and taking
# that exit first would report a broken contract — `--shas '' --status ok`, or
# `--status unavailable` — as a clean author-written verdict instead of the
# documented exit 3. Contract violations outrank every verdict.

# --- The durable set: GRIND_SHAS / GRIND_SHAS_STATUS (STRICT) -----------------
# Exhaustive presence table. The two fields are only ever emitted together
# (grind-pr-commits.sh --context guarantees it), so any half-present pair means
# the contract broke somewhere between producer and worker.
#
#   absent  / absent      -> pre-contract dispatcher; empty durable set, no BAIL
#   present / absent      -> BAIL
#   absent  / present     -> BAIL
#   any     / unavailable -> BAIL (the dispatcher should have BAILed first)
#   any     / other       -> BAIL
#   "none"  / ok          -> empty durable set
#   ""|ws   / ok          -> BAIL (the producer renders "none", never empty)
#   list    / ok          -> validate every token
durable_set=""

if [ "$HAVE_SHAS" -eq 0 ] && [ "$HAVE_STATUS" -eq 0 ]; then
    # Pre-contract dispatcher (mixed-version rollout): empty durable set. A
    # stray --head with no set to bind is still a broken contract.
    [ "$HAVE_HEAD" -eq 0 ] \
        || contract_violation "GRIND_HEAD_SHA supplied without GRIND_SHAS/GRIND_SHAS_STATUS"
elif [ "$HAVE_SHAS" -eq 1 ] && [ "$HAVE_STATUS" -eq 0 ]; then
    contract_violation "GRIND_SHAS present without GRIND_SHAS_STATUS"
elif [ "$HAVE_SHAS" -eq 0 ] && [ "$HAVE_STATUS" -eq 1 ]; then
    contract_violation "GRIND_SHAS_STATUS present without GRIND_SHAS"
else
    # The certified set is a SNAPSHOT, taken at a specific HEAD before dispatch.
    # pr-grind explicitly contemplates concurrent runs, so another invocation can
    # advance the shared worktree between that scan and this blame. Its new
    # commit would then be in neither GRIND_SHAS nor this invocation's
    # PRIOR_ATTEMPTS, and findings on it would read as author-written - silently
    # re-inerting the gate. Binding the set to the HEAD it was derived at turns
    # that into a visible BAIL.
    [ "$HAVE_HEAD" -eq 1 ] \
        || contract_violation "GRIND_SHAS/GRIND_SHAS_STATUS supplied without GRIND_HEAD_SHA; the certified set must name the HEAD it was derived at"
    _head_now=$(command git -C "$REPO_DIR" rev-parse HEAD) \
        || contract_violation "cannot resolve HEAD in $REPO_DIR to re-check the certified set"
    [ "$_head_now" = "$HEAD_AT_SCAN" ] \
        || contract_violation "the worktree advanced since the set was certified (GRIND_HEAD_SHA=$HEAD_AT_SCAN, HEAD is now $_head_now); the durable set is stale — re-derive it"

    case "$STATUS" in
        ok) : ;;
        unavailable)
            contract_violation "GRIND_SHAS_STATUS=unavailable reached the worker; the dispatcher must BAIL env before dispatch"
            ;;
        *)
            contract_violation "GRIND_SHAS_STATUS must be 'ok' or 'unavailable', got '$STATUS'"
            ;;
    esac

    if [ -z "${SHAS//[[:space:]]/}" ]; then
        contract_violation "GRIND_SHAS is empty or whitespace under STATUS=ok; the producer renders 'none' for an empty set"
    fi
    # Any whitespace at all is a violation rather than something to strip: the
    # producer emits a bare comma list, so embedded whitespace means the field
    # was mangled in transport, and stripping it would forge a valid-looking OID
    # out of two mangled halves.
    case "$SHAS" in
        *[[:space:]]*)
            contract_violation "GRIND_SHAS contains whitespace: '$SHAS'" ;;
    esac
    _trimmed="$SHAS"

    if [ "$_trimmed" != "none" ]; then
        # Empty fields must be caught BEFORE word splitting, not by the
        # per-token emptiness check below: IFS splitting collapses leading and
        # trailing separators, so "sha," yields exactly one token and a mangled
        # field would validate clean. Measured - this is why the check is here.
        case ",${_trimmed}," in
            *,,*)
                contract_violation "GRIND_SHAS contains an empty token (leading, trailing, or doubled comma): '$SHAS'" ;;
        esac

        _IFS_SAVE=$IFS
        IFS=','
        # shellcheck disable=SC2086  # deliberate word split on the comma list
        set -- $_trimmed
        IFS=$_IFS_SAVE
        [ $# -gt 0 ] || contract_violation "GRIND_SHAS contains no tokens: '$SHAS'"
        for _tok in "$@"; do
            [ -n "$_tok" ] \
                || contract_violation "GRIND_SHAS contains an empty token (stray or doubled comma): '$SHAS'"
            case "$_tok" in
                *[!0-9a-f]*)
                    contract_violation "GRIND_SHAS token is not lowercase hex: '$_tok'" ;;
            esac
            [ "${#_tok}" -eq "$_oid_len" ] \
                || contract_violation "GRIND_SHAS token is not a full ${_oid_len}-character OID: '$_tok'"
            _peeled=$(command git -C "$REPO_DIR" rev-parse --verify --quiet "${_tok}^{commit}") \
                || contract_violation "GRIND_SHAS token does not resolve to a commit: '$_tok'"
            # `^{commit}` PEELS, so an annotated tag's OID verifies successfully
            # while naming a different object. Storing the token unpeeled would
            # then never match the blamed commit - a silent non-membership where
            # the certified set is actually malformed. Require the token to BE
            # the commit; the producer emits nothing else.
            [ "$_peeled" = "$_tok" ] || contract_violation \
                "GRIND_SHAS token is not itself a commit OID (it peels to $_peeled — an annotated tag or other object): '$_tok'"
            durable_set="${durable_set}${_tok}"$'\n'
        done
    fi
fi

# --- The inherited set: PRIOR_ATTEMPTS commit= values (fail-OPEN) -------------
# Backward compatibility: "none" is the wait-round sentinel and anything that
# does not resolve is dropped, exactly as agents/pr-grinder.md:300 already says.
prior_set=""
if [ -n "$PRIOR" ]; then
    _IFS_SAVE=$IFS
    IFS=','
    # shellcheck disable=SC2086  # deliberate word split on the comma list
    set -- $PRIOR
    IFS=$_IFS_SAVE
    for _tok in "$@"; do
        _tok=${_tok#commit=}
        [ -n "$_tok" ] || continue
        [ "$_tok" != "none" ] || continue
        _resolved=$(command git -C "$REPO_DIR" rev-parse --verify --quiet "${_tok}^{commit}") || continue
        prior_set="${prior_set}${_resolved}"$'\n'
    done
fi

# --- The blamed SHA (resolved only after the contract has been validated) -----
# A FULL-WIDTH all-zero OID is blame's marker for a not-yet-committed line. It
# has no provenance, so it is author-written by definition - and `git rev-parse
# 0000...^{commit}` is fatal, not merely empty, so this must precede
# normalization.
#
# The width check is load-bearing: a bare `*[!0]*` case also matches "0" or
# "00", so a malformed input would be silently reported as author-written
# instead of failing validation. Only the real marker takes this exit.
case "$BLAMED" in
    *[!0]*) : ;;
    *)      [ "${#BLAMED}" -eq "$_oid_len" ] && exit 1 ;;
esac

blamed_full=$(command git -C "$REPO_DIR" rev-parse --verify --quiet "${BLAMED}^{commit}") \
    || contract_violation "blamed SHA does not resolve to a commit: $BLAMED"

# --- Membership ---------------------------------------------------------------
# Pure-bash exact-line lookup: no external command, so there is nothing here to
# shadow and no exit status to misread. An earlier version piped the set through
# `grep -qxF`, which meant a stubbed `grep` returning 1 could classify a genuine
# durable-set member as author-written and silently disable the gate — and the
# git canary above cannot see that, because it only proves `git`. Removing the
# dependency closes the hole outright rather than adding a second canary.
#
# Both sets are built with a trailing newline per entry, so prefixing one makes
# the match exact-line. The blamed OID is validated hex, so it carries no glob
# metacharacters.
case $'\n'"${durable_set}${prior_set}" in
    *$'\n'"$blamed_full"$'\n'*) exit 0 ;;
esac
exit 1
