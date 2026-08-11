#!/usr/bin/env bash
# scripts/grind-pr-commits.sh - derive the set of grind-written commits for a PR.
#
# Rail A of durable grind provenance (ADR 0036). #620's proportionality gate
# sources provenance solely from PRIOR_ATTEMPTS, which pr-grind re-initializes
# empty on every invocation - so on a fresh invocation of an already-ground PR
# the gate is inert. This script is the durable replacement: it reads the branch
# itself.
#
# Usage:
#   grind-pr-commits.sh [--context] -C <repo_dir> <pr_number> <base_sha> <head_sha>
#
# Output (default):  one full SHA per line, possibly empty.
# Output (--context): exactly two lines, ready to paste into the worker prompt:
#                       GRIND_SHAS=<sha>,<sha>,...   or   GRIND_SHAS=none
#                       GRIND_SHAS_STATUS=ok
#                     --context exists so the "empty set renders none, not 1"
#                     rule is executable rather than prose in a caller's head
#                     (`helper | wc -l` on empty output returns 1).
#
# Exit codes:
#   0  scan succeeded (the set may be empty)
#   2  usage error, including a non-numeric or leading-zero PR number
#   3  SCAN FAILED - unresolvable ref, wrong-shaped range, shallow repo, git
#      error. Deliberately distinct from "empty set": the caller BAILs env on 3
#      and must never read a scan failure as "no grind commits".
#
# Invocation contract:
#   -C <repo_dir> is REQUIRED and is passed through to every git call. Agent
#   Bash calls reset CWD between invocations and the worktree may be the repo
#   root under the NO_WORKTREE fallback, so this script never reads its own CWD.
#   <head_sha> must be the caller's already-resolved full OID, not the literal
#   "HEAD" and not a branch name, so the scan cannot read a different tree than
#   the one the worker will blame.

set -uo pipefail

# -C is this script's repository boundary, and inherited git environment
# variables OVERRIDE it: with GIT_DIR pointing elsewhere, `git -C /some/dir`
# reports the OTHER repository, so a scan invoked with a correct -C could derive
# its provenance set from somewhere else entirely and still report
# GRIND_SHAS_STATUS=ok. Gate env is repo-injectable in this project
# (#325 / ADR 0016), so clear them rather than trust the caller's environment.
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
      GIT_EXEC_PATH GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT \
      GIT_CONFIG_PARAMETERS

# Repository-local refs/replace entries rewrite what git reports for a commit.
# A replacement preserving tree and parents but dropping the Grind-PR trailer
# and the transitional subject would make both scans omit a REAL grind commit
# while still reporting STATUS=ok — a fail-OPEN that needs no environment access
# at all, only a ref in the repository being scanned.
export GIT_NO_REPLACE_OBJECTS=1

# GIT_CONFIG_PARAMETERS is not a footnote in that list: it injects arbitrary
# config, and `trailer.separators=#` alone makes `%(trailers)` omit an exact
# `Grind-PR: N` line that `rev-list --grep` still matches — silently discarding a
# REAL grind commit while the scan reports STATUS=ok.

# Clearing variables is not enough on its own: bash imports environment entries
# named `BASH_FUNC_<name>%%` as shell FUNCTIONS, which shadow the real binaries
# at every call site here. A committed settings.json env block can set those
# (#325 / ADR 0016). Unsetting only `git` is insufficient — a stubbed `grep`
# returning 1 makes the SHA filter look like a legitimate empty match, so the
# scan emits GRIND_SHAS=none / STATUS=ok / exit 0 even after git succeeded.
#
# So drop EVERY inherited function, before this script defines its own and
# before any external command runs. Parsed with builtins only (`declare`,
# `read`, `unset`) — using awk or sed here would be the same hole one level up.
while read -r _d _flag _name; do
    [ -n "${_name:-}" ] && unset -f "$_name"
done <<< "$(declare -F)"
unset _d _flag _name

# The cleanup above is defense-in-depth, NOT the boundary — and it is important
# to be precise about that rather than to keep hardening it. It runs `declare`,
# `read` and `unset` as bare names while inherited functions are still live, so
# a stubbed `declare` or `unset` defeats it; so does BASH_ENV, or a PATH that
# resolves the interpreter itself. That regress does not terminate: any check
# written here is expressible in terms the attacker also controls. The real
# boundary is the caller's environment sanitization (#325 / ADR 0016), which
# strips gate env before this script is ever invoked.
#
# The canary below is a TRIPWIRE, not authentication of the binary. It catches
# every cheap variant at once — inherited function, alias, PATH hijack, defeated
# cleanup — because each has to survive this call. It does NOT catch a stub that
# emulates `git --version` and then lies about everything after, and no in-script
# check can: at that point the attacker is running arbitrary code in this process
# and could equally have replaced the script. `command` bypasses function lookup,
# so the three layers here (unset, `command`, canary) are independent — but the
# boundary remains the caller's env sanitization.
_gv=$(command git --version 2>/dev/null) || _gv=""
case "$_gv" in
    "git version "*) : ;;
    *)
        printf 'grind-pr-commits.sh: SCAN FAILED: `git` does not resolve to the real git binary (shadowed function, alias, or PATH hijack); got %s\n' \
            "${_gv:-no output}" >&2
        exit 3
        ;;
esac
unset _gv

usage_error() {
    printf 'grind-pr-commits.sh: %s\n' "$1" >&2
    exit 2
}

scan_failed() {
    printf 'grind-pr-commits.sh: SCAN FAILED: %s\n' "$1" >&2
    exit 3
}

CONTEXT_MODE=0
REPO_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --context) CONTEXT_MODE=1; shift ;;
        -C)
            [ $# -ge 2 ] || usage_error "-C requires a directory argument"
            REPO_DIR="$2"; shift 2
            ;;
        --) shift; break ;;
        -*) usage_error "unknown option: $1" ;;
        *) break ;;
    esac
done

[ $# -eq 3 ] || usage_error \
    "usage: grind-pr-commits.sh [--context] -C <repo_dir> <pr_number> <base_sha> <head_sha>"

PR_NUMBER="$1"
BASE_SHA="$2"
HEAD_SHA="$3"

[ -n "$REPO_DIR" ] || usage_error "-C <repo_dir> is required"
[ -d "$REPO_DIR" ] || usage_error "-C: not a directory: $REPO_DIR"

# Leading zeros are rejected, not merely non-digits: "0617" would stamp a
# trailer that a later "617" scan silently misses - an under-count with no error.
case "$PR_NUMBER" in
    ''|*[!0-9]*|0*)
        usage_error "PR number must match ^[1-9][0-9]*\$: '$PR_NUMBER'"
        ;;
esac

command git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 \
    || scan_failed "not a git repository: $REPO_DIR"

# Enforce the documented snapshot-binding contract rather than merely stating it.
# `rev-parse` happily accepts `HEAD`, a branch name, or an abbreviation, so
# without this check an invocation passing `HEAD` scans whatever the tree is at
# THIS moment — which can be a different commit than the one the worker later
# blames, silently breaking the binding the contract exists to provide.
#
# The width comes from THIS repository's object format, not from a 40-or-64
# alternation: in a SHA-256 repo a 40-character value is an abbreviation that
# `rev-parse --verify` resolves happily, so a blanket alternation would leave the
# abbreviation path open in exactly the repo where it is hardest to notice.
case "$(command git -C "$REPO_DIR" rev-parse --show-object-format 2>/dev/null)" in
    sha1)   _oid_len=40 ;;
    sha256) _oid_len=64 ;;
    *)      scan_failed "cannot determine the repository's object format" ;;
esac

for _arg in "$BASE_SHA" "$HEAD_SHA"; do
    _ok=0
    case "$_arg" in
        *[!0-9a-f]*) ;;
        *) [ "${#_arg}" -eq "$_oid_len" ] && _ok=1 ;;
    esac
    [ "$_ok" -eq 1 ] || usage_error \
        "base and head must be full ${_oid_len}-character lowercase-hex OIDs already resolved by the caller (not 'HEAD', a branch name, or an abbreviation); got '$_arg'"
done

# A shallow clone returns rc 0 over a truncated ancestry, silently under-counting
# the set - which degrades straight back to the inert gate this script exists to
# fix. Refuse loudly instead.
if [ "$(command git -C "$REPO_DIR" rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    scan_failed "shallow repository: ancestry is truncated so the grind-commit set cannot be derived (git fetch --unshallow)"
fi

base_full=$(command git -C "$REPO_DIR" rev-parse --verify --quiet "${BASE_SHA}^{commit}") \
    || scan_failed "base does not resolve to a commit in $REPO_DIR: $BASE_SHA"
head_full=$(command git -C "$REPO_DIR" rev-parse --verify --quiet "${HEAD_SHA}^{commit}") \
    || scan_failed "head does not resolve to a commit in $REPO_DIR: $HEAD_SHA"

# Range SHAPE, not just exit status. `git rev-list A..B` returns rc 0 for ANY
# pair. When base is not an ancestor of head - a base rewrite or a retarget to
# an unrelated branch - trunk history re-enters the range, bringing squash
# commits whose bodies concatenate every branch commit's message (verified on
# 924cbdea) and therefore carry Grind-PR: lines. That is exactly the false-BAIL
# vector range scoping is supposed to close.
command git -C "$REPO_DIR" merge-base --is-ancestor "$base_full" "$head_full" \
    || scan_failed "base is not an ancestor of head ($BASE_SHA .. $HEAD_SHA); the range would include trunk history"

# Arm 1: the durable trailer. --grep is line-anchored but NOT end-anchored, so
# the trailing $ is load-bearing: '^Grind-PR: 61' matches 'Grind-PR: 617'.
# Scanning the body is correct here - that is where trailers live.
arm1_candidates=$(command git -C "$REPO_DIR" rev-list --grep="^Grind-PR: ${PR_NUMBER}\$" "${base_full}..${head_full}")
rc=$?
[ "$rc" -eq 0 ] || scan_failed "trailer scan failed (git rev-list exit $rc)"

# --grep matches ANY line of the message, including body prose. An author commit
# that quotes an exact `Grind-PR: 617` line — in an example, a changelog entry,
# or a review quote — would otherwise be attributed to the grind and trigger a
# false BAIL on the author's own code.
#
# So confirm each candidate by matching the exact line against the PARSED
# TRAILER BLOCK rather than the whole message. `%(trailers)` emits only the
# trailer paragraph, verbatim — measured on git 2.55.0: a commit whose body
# quotes `Grind-PR: 617` in prose and whose real trailer is `grind-pr:617`
# prints only `grind-pr:617`, which this exact-line grep rejects.
#
# One predicate on the right text beats two on the wrong one. Checking the
# parsed VALUE instead (`%(trailers:key=…,valueonly=true)`) is not equivalent:
# git's parser is case-insensitive and space-tolerant, so that commit returns
# `617` and the prose quote would still be counted.
arm1=""
while IFS= read -r _cand; do
    [ -n "$_cand" ] || continue
    # -c trailer.separators=':' pins the parse. Clearing the env var above stops
    # one injection route, but repository config can set the same key, and this
    # predicate must mean the same thing in every repo it runs in.
    _block=$(command git -c trailer.separators=':' -C "$REPO_DIR" \
        log -1 --format='%(trailers)' "$_cand")
    rc=$?
    [ "$rc" -eq 0 ] || scan_failed "trailer parse failed for $_cand (git log exit $rc)"
    # Exact-line match in PURE BASH, no grep. Every external command here is
    # another name an inherited function or PATH entry can shadow, and a stubbed
    # `grep` returning 1 reads as "no matching trailer" — dropping every
    # candidate and emitting GRIND_SHAS=none with STATUS=ok while grind commits
    # sit in range. The git canary cannot see that, because `command git` still
    # reaches real git. Removing the dependency closes it outright.
    case $'\n'"$_block"$'\n' in
        *$'\n'"Grind-PR: ${PR_NUMBER}"$'\n'*) arm1="${arm1}${_cand}"$'\n' ;;
    esac
done <<< "$arm1_candidates"

# Arm 2 (transitional): the unconditional subject composed at
# dispatcher-commit-block.sh:949, covering branches already open at rollout.
#
# Two mechanical constraints, both measured:
#   - Match the SUBJECT only, never via --grep: --grep matches body lines too,
#     so an author commit whose body quotes "fix: address PR #617 feedback"
#     would be counted as grind-written.
#   - Read line pairs, never a NUL delimiter: `$(git log --format='%H%x00%s')`
#     drops the NUL in command substitution (bash 5.3.15 warns and discards),
#     concatenating <40hex><subject> so the arm can never fire. %s is
#     single-line by construction, so %H%n%s pairs exactly.
pairs=$(command git -C "$REPO_DIR" log --format='%H%n%s' "${base_full}..${head_full}")
rc=$?
[ "$rc" -eq 0 ] || scan_failed "subject scan failed (git log exit $rc)"

arm2=""
_sha=""
_expect_subject=0
while IFS= read -r _line; do
    if [ "$_expect_subject" -eq 0 ]; then
        _sha="$_line"
        _expect_subject=1
    else
        _expect_subject=0
        if [ "$_line" = "fix: address PR #${PR_NUMBER} feedback" ]; then
            arm2="${arm2}${_sha}"$'\n'
        fi
    fi
done <<< "$pairs"

# Each scan's status was checked separately ABOVE, before any pipeline:
# `{ a; b; } | sort -u` takes its status from sort, masking git's 128 and
# returning an empty set with rc 0 - fail-open on the exact property Rail A
# relies on. By here both scans have succeeded, so an empty result is a
# legitimately empty set rather than a failure.
#
# Merge, filter and dedup in PURE BASH. `grep`, `sort` and `tr` are three more
# names an inherited function or a PATH entry can shadow, and a stub returning 1
# reads as "nothing matched" — GRIND_SHAS=none with STATUS=ok while grind
# commits sit in range. The git canary cannot catch that (`command git` still
# reaches real git), so the dependency is removed instead of guarded. `git` is
# now the only external command this script runs.
#
# Width comes from the repo's own OID length rather than a hardcoded 40, so a
# SHA-256 repository cannot silently filter every SHA out.
sha_len=${#base_full}
combined=""
while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    case "$_line" in *[!0-9a-f]*) continue ;; esac
    [ "${#_line}" -eq "$sha_len" ] || continue
    case $'\n'"$combined" in
        *$'\n'"$_line"$'\n'*) continue ;;   # dedup: already collected
    esac
    combined="${combined}${_line}"$'\n'
done <<< "${arm1}${arm2}"

if [ "$CONTEXT_MODE" -eq 1 ]; then
    if [ -z "$combined" ]; then
        printf 'GRIND_SHAS=none\n'
    else
        _joined=""
        while IFS= read -r _line; do
            [ -n "$_line" ] || continue
            if [ -z "$_joined" ]; then
                _joined="$_line"
            else
                _joined="${_joined},${_line}"
            fi
        done <<< "$combined"
        printf 'GRIND_SHAS=%s\n' "$_joined"
    fi
    printf 'GRIND_SHAS_STATUS=ok\n'
else
    # $combined already carries one trailing newline per entry.
    [ -z "$combined" ] || printf '%s' "$combined"
fi

exit 0
