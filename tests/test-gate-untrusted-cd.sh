#!/usr/bin/env bash
# Untrusted-cd repo scoping: gitcmd_detect._untrusted_cd + gate_resolve_repo_dir $3.
#
# THE BUG THIS PINS. A `cd` is trusted as the repo scope only when '&&'-joined to the
# gated command (if the cd fails, the command never runs). Behind ';' or a newline the
# cd's execution is statically unknowable, and the parser reported '' — the same value
# as "no cd at all" — so the gates silently anchored on the PreToolUse cwd. For the
# common shape
#
#     cd /other-repo
#     git commit -m x
#
# the cd DOES succeed, so the commit lands in /other-repo while the gate checked the
# SESSION repo. Marker existence is the sole check, and both the marker and
# skip-*.local are $REPO_DIR-scoped, so a fresh marker or a live skip file in the
# session repo authorized an UNREVIEWED commit in /other-repo. Fail-OPEN.
#
# THE FIX. The operand is surfaced OUT OF BAND (opt-in 4th tuple element) and passed
# as gate_resolve_repo_dir's $3. The resolver proceeds only when the cd PROVABLY
# cannot leave the cwd repo — an ABSOLUTE, '..'-free, metachar-free literal whose
# `rev-parse --show-toplevel` equals the cwd's — and blocks otherwise.
#
# Three things this must NOT do, each pinned below:
#   1. Fold the flag into target_dir. A sentinel prefix is in-band signalling: a real
#      directory can imitate it, and since any '$'-carrying target is unresolvable
#      (BLOCK), overloading the field DOWNGRADED `cd '$untrusted-cd:x' && git commit`
#      to proceed. Hence the separate parameter (case: "sentinel-lookalike").
#   2. Treat an empty cd_root as proof the cd failed. The directory may simply sit
#      outside every repo, where `gh pr merge` still resolves a PR (remote or -R) even
#      though `git commit` would not (case: "cd to non-repo").
#   3. Compare a RELATIVE or '..'-bearing operand. CDPATH can send `cd sub` outside
#      the payload cwd, and '..' resolves differently under bash's logical cd than
#      under the physical `git -C` (cases: "relative", "dotdot").
#
# Usage: bash tests/test-gate-untrusted-cd.sh   (exit 0 all pass, 1 any fail)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

LIB_DIR="$(pwd)/hooks/gate-scripts/lib"
# shellcheck source=hooks/gate-scripts/lib/resolve-repo-dir.sh
. "$LIB_DIR/resolve-repo-dir.sh"

fails=0

# Real repos: the resolver compares `rev-parse --show-toplevel` of the cd target
# against the cwd's, so throwaway git repos keep this self-contained and independent
# of the host layout.
TMP_ROOT=$(mktemp -d) || { echo "mktemp -d failed" >&2; exit 1; }
# Empty/relative TMP_ROOT would build the fixtures at the FILESYSTEM ROOT
# (/session-repo, /other-repo) and the trap would not clean them up. Refuse.
case "$TMP_ROOT" in /?*) ;; *) echo "unusable TMP_ROOT: '$TMP_ROOT'" >&2; exit 1 ;; esac
trap 'rm -rf "$TMP_ROOT"' EXIT
CWD_REPO="$TMP_ROOT/session-repo"
OTHER_REPO="$TMP_ROOT/other-repo"
for r in "$CWD_REPO" "$OTHER_REPO"; do
    mkdir -p "$r" || { echo "mkdir $r failed" >&2; exit 1; }
    git -C "$r" init -q 2>/dev/null || { echo "git init $r failed" >&2; exit 1; }
done
# Compare against what `rev-parse --show-toplevel` actually reports: on macOS mktemp
# yields /var/... while git resolves the symlink to /private/var/..., so raw mktemp
# paths would fail on path shape alone and mask the real statuses.
# Guard the reassignments: without `set -e`, a failed rev-parse would blank these
# and the mkdir below would build fixtures at the filesystem root, outside the trap.
CWD_REPO=$(git -C "$CWD_REPO" rev-parse --show-toplevel) || { echo "rev-parse failed" >&2; exit 1; }
OTHER_REPO=$(git -C "$OTHER_REPO" rev-parse --show-toplevel) || { echo "rev-parse failed" >&2; exit 1; }
# Absolute-and-non-empty is the property that matters; do NOT compare against
# $TMP_ROOT, which on macOS is the /var symlink while git reports /private/var.
for _r in "$CWD_REPO" "$OTHER_REPO"; do
    case "$_r" in /?*) ;; *) echo "unusable fixture path: '$_r'" >&2; exit 1 ;; esac
done
mkdir -p "$CWD_REPO/sub/dir"
NON_REPO="$TMP_ROOT/plain-dir"
mkdir -p "$NON_REPO"

# Drive the REAL parser then the REAL resolver — no hand-built inputs, so a change to
# either side's contract fails here instead of passing against a stale mock.
expect() { # $1=label  $2=command  $3=expected status  [$4=expected repo]
    local label="$1" cmd="$2" exp_status="$3" exp_repo="${4:-}" parsed target untrusted
    parsed=$(PYTHONPATH="$LIB_DIR" python3 -c '
import sys
from gitcmd_detect import git_commit
_c, target, _a, untrusted = git_commit(sys.argv[1], with_untrusted_cd=True)
print(target)
print(untrusted)' "$cmd")
    target=$(printf '%s' "$parsed" | sed -n '1p')
    untrusted=$(printf '%s' "$parsed" | sed -n '2p')
    gate_resolve_repo_dir "$target" "$CWD_REPO" "$untrusted"
    local ok=1
    [ "$GATE_RESOLVE_STATUS" = "$exp_status" ] || ok=0
    if [ -n "$exp_repo" ] && [ "$GATE_REPO_DIR" != "$exp_repo" ]; then ok=0; fi
    if [ "$ok" = 1 ]; then
        printf '  PASS  %-50s status=%s\n' "$label" "$GATE_RESOLVE_STATUS"
    else
        fails=$((fails + 1))
        printf '  FAIL  %-50s exp=%s/%s got=%s/%s\n' \
            "$label" "$exp_status" "${exp_repo:-<any>}" "$GATE_RESOLVE_STATUS" "${GATE_REPO_DIR:-<none>}"
    fi
}

echo "── cross-repo, cd NOT '&&'-joined → MUST BLOCK (the bypass) ──────────"
expect "cd OTHER + newline"        "cd $OTHER_REPO"$'\n'"git commit -m x" block-unresolvable
expect "cd OTHER + semicolon"      "cd $OTHER_REPO ; git commit -m x"     block-unresolvable
expect "cd OTHER + background &"   "cd $OTHER_REPO & git commit -m x"     block-unresolvable

echo "── cd survives intervening commands (adjacency is the WRONG rule) ─────"
# '&&'-trust needs adjacency, but "might the cwd have moved?" does not: an
# intervening command does not undo a cd, so these still run in OTHER.
expect "cd OTHER ; noop ; commit"  "cd $OTHER_REPO ; : ; git commit -m x"  block-unresolvable
expect "cd OTHER ; echo ; commit"  "cd $OTHER_REPO ; echo hi ; git commit -m x" block-unresolvable
# '&&' on the command proves nothing about a NON-adjacent cd: here it joins the
# no-op to the commit, so the cd is still unconfirmed and still in effect.
expect "cd OTHER ; noop && commit"  "cd $OTHER_REPO ; : && git commit -m x" block-unresolvable
# TWO DIFFERENT cds → we cannot say which ran, so neither may be assumed. Lexical
# order is not execution order: in `cd A || cd B` the second runs only if A FAILED.
expect "cd SAME then cd OTHER"     "cd $CWD_REPO ; cd $OTHER_REPO ; git commit -m x" block-unresolvable
expect "cd OTHER then cd SAME"     "cd $OTHER_REPO ; cd $CWD_REPO ; git commit -m x" block-unresolvable
expect "cd OTHER || cd SAME"       "cd $OTHER_REPO || cd $CWD_REPO ; git commit -m x" block-unresolvable
# Bash groups '&&'/'||' left-to-right at equal precedence, so this runs as
# (cd OTHER || cd SAME) && commit — the commit can execute with the SECOND cd
# SKIPPED, landing in OTHER. An adjacent '&&' is therefore NOT proof on its own,
# and neither is the absolute target it produced.
expect "cd OTHER || cd SAME && commit" "cd $OTHER_REPO || cd $CWD_REPO && git commit -m x" block-unresolvable

echo "── nested chunks inherit the OUTER cwd ────────────────────────────────"
# `bash -c`/`$(...)` bodies are scanned with allow_cd=False (their own cwd is a
# subshell's), but they still INHERIT the directory the outer command moved to.
expect "cd OTHER ; bash -c commit"  "cd $OTHER_REPO ; bash -c 'git commit -m x'"   block-unresolvable
expect "cd OTHER ; \$(commit)"       "cd $OTHER_REPO ; echo \$(git commit -m x)"    block-unresolvable
expect "cd SAME ; bash -c commit"   "cd $CWD_REPO ; bash -c 'git commit -m x'"     proceed "$CWD_REPO"
expect "bash -c commit, no outer cd" "bash -c 'git commit -m x'"                   proceed "$CWD_REPO"
# A cd INSIDE the payload runs before the nested command just the same.
expect "bash -c 'cd OTHER; commit'" "bash -c 'cd $OTHER_REPO; git commit -m x'"    block-unresolvable
expect "bash -c 'cd SAME; commit'"  "bash -c 'cd $CWD_REPO; git commit -m x'"      proceed "$CWD_REPO"
# Ordering is NOT modelled across interpreter payloads (see _nested_cds): locating a
# payload inside its parent by substring picks inert text just as readily as the
# segment that runs it, and payloads nest arbitrarily. So every cd in the command
# counts, which is order-independent and sound — at the cost of blocking a nested
# command whose only cd runs AFTER it. Fail-CLOSED, and '&&'/git -C clears it.
expect "bash -c commit ; cd OTHER (accepted)" "bash -c 'git commit -m x' ; cd $OTHER_REPO" block-unresolvable
expect "bash -c 'commit; cd OTHER' (accepted)" "bash -c 'git commit -m x; cd $OTHER_REPO'" block-unresolvable
# Inert text naming the command must not shadow a real cd (substring-match trap).
expect "echo decoy ; cd OTHER ; bash -c commit" \
    "echo 'git commit' ; cd $OTHER_REPO ; bash -c 'git commit -m x'"               block-unresolvable
# Intermediate payloads count too, not just outermost and leaf.
expect "nested twice, cd in the middle" \
    "bash -c 'cd $OTHER_REPO; bash -c \"git commit -m x\"'"                        block-unresolvable
# The same cd repeated is unambiguous whichever one ran.
expect "cd SAME twice"             "cd $CWD_REPO ; cd $CWD_REPO ; git commit -m x" proceed "$CWD_REPO"
# A RELATIVE `git -C` is resolved by git against the RUNTIME cwd but by the gate
# against the payload cwd; with an unconfirmed cd in play they disagree.
expect "relative git -C after cd"  "cd $OTHER_REPO ; git -C . commit"     block-unresolvable
# An ABSOLUTE -C fixes the repo by itself, so a preceding cd is irrelevant.
expect "absolute git -C after cd"  "cd $OTHER_REPO ; git -C $CWD_REPO commit" proceed "$CWD_REPO"

echo "── cds the strict detector cannot see ─────────────────────────────────"
# A KEYWORD-prefixed cd is never TRUSTED (it may be conditional) but it may well
# have RUN, so it must still be seen — _cd_target_loose.
expect "if cd OTHER; then ...; commit" "if cd $OTHER_REPO; then :; fi; git commit -m x" block-unresolvable
expect "if cd SAME; then ...; commit"  "if cd $CWD_REPO; then :; fi; git commit -m x"  proceed "$CWD_REPO"
# A CURRENT-SHELL payload changes the cwd of the chunk we matched in, unlike a
# `bash -c` subshell — and the two are indistinguishable here, so both count.
expect "eval 'cd OTHER' ; commit"   "eval 'cd $OTHER_REPO' ; git commit -m x"      block-unresolvable
expect "eval 'cd SAME' ; commit"    "eval 'cd $CWD_REPO' ; git commit -m x"        proceed "$CWD_REPO"
# A cd AFTER the command in the SAME chunk is ordered exactly and must not block.
expect "commit ; cd OTHER (ordered)" "git commit -m x ; cd $OTHER_REPO"            proceed "$CWD_REPO"
# Prefixes that still change the CURRENT shell's directory.
expect "builtin cd OTHER"          "builtin cd $OTHER_REPO ; git commit -m x"      block-unresolvable
expect "command cd OTHER"          "command cd $OTHER_REPO ; git commit -m x"      block-unresolvable
expect "assignment-prefixed cd"    "X=1 cd $OTHER_REPO ; git commit -m x"          block-unresolvable
expect "quoted command word"       "\"cd\" $OTHER_REPO ; git commit -m x"          block-unresolvable
# A bare `cd` goes to $HOME — a destination this parser cannot know.
expect "bare cd (unknown dest)"    "cd"$'\n'"git commit -m x"                      block-unresolvable
# Command-word resolution is delegated to _command_argv (the same tokenizer that
# finds git/gh), so wrapper options, end-of-options, redirections and case labels
# are all inherited rather than re-implemented.
expect "case branch label"         "case x in x) cd $OTHER_REPO;; esac; git commit -m x" block-unresolvable
expect "builtin -- cd"             "builtin -- cd $OTHER_REPO ; git commit -m x"   block-unresolvable
expect "command -p cd"             "command -p cd $OTHER_REPO ; git commit -m x"   block-unresolvable
expect "time -p cd"                "time -p cd $OTHER_REPO ; git commit -m x"      block-unresolvable
expect "leading redirection"       ">/dev/null cd $OTHER_REPO ; git commit -m x"   block-unresolvable
# A TRAILING redirection must not end up inside the compared path: the strict regex
# keeps everything after `cd `, and `/other >/dev/null` is a string an attacker can
# create as a symlink into the session repo while bash strips it and moves elsewhere.
expect "trailing redirection"      "cd $OTHER_REPO >/dev/null ; git commit -m x"   block-unresolvable
expect "trailing 2>&1"             "cd $OTHER_REPO 2>&1 ; git commit -m x"         block-unresolvable
# ANSI-C quoting still runs the builtin.
expect "ANSI-C \$'cd' spelling"     "\$'cd' $OTHER_REPO ; git commit -m x"          block-unresolvable
# An ABSOLUTE `git -C` fixes the repo whatever a payload did — never overridden.
expect "eval cd + absolute git -C" "eval 'cd $OTHER_REPO' ; git -C $CWD_REPO commit" proceed "$CWD_REPO"
# Only an ABSOLUTE trusted cd is authoritative: a RELATIVE one composes with whatever
# earlier cds did (`cd /other; cd sub && commit` runs in /other/sub, not cwd/sub).
expect "relative cd after cd, '&&'"  "cd $OTHER_REPO ; cd sub && git commit -m x"   block-unresolvable
# `cd ~` expands to $HOME but `cd "~"` is a LITERAL dir named '~'; tokenization has
# discarded which was written, so the destination is unknown.
expect "tilde operand (quoting lost)" "cd ~"$'\n'"git commit -m x"                  block-unresolvable

echo "── unprovable destination → MUST BLOCK (fail-closed, not guessed) ─────"
# Empty cd_root is NOT proof the cd failed (limitation 2 in the header).
expect "cd to non-repo dir"        "cd $NON_REPO"$'\n'"git commit -m x"   block-unresolvable
expect "cd to nonexistent dir"     "cd $TMP_ROOT/nope"$'\n'"git commit -m x" block-unresolvable
# CDPATH / logical-vs-physical divergence (limitation 3).
expect "relative operand"          "cd sub/dir"$'\n'"git commit -m x"     block-unresolvable
expect "dotdot operand"            "cd $CWD_REPO/sub/.."$'\n'"git commit -m x" block-unresolvable
expect "cd . (relative)"           "cd ."$'\n'"git commit -m x"           block-unresolvable
# Already fail-CLOSED shapes must not be widened by arriving via an untrusted cd.
# SC2016: the LITERAL '$DIR' is the parser input under test.
# shellcheck disable=SC2016
expect "cd \$VAR"                   'cd $DIR'$'\n'"git commit -m x"        block-unresolvable
expect "cd -"                      "cd -"$'\n'"git commit -m x"           block-unresolvable
expect "cd glob"                   "cd /tmp/*"$'\n'"git commit -m x"      block-unresolvable
# EXTGLOB — @(a|b), +(a), !(a) — expands under `shopt -s extglob` just like a glob,
# so the operand is not the literal directory it looks like.
expect "cd extglob @( )"           "cd $CWD_REPO/@(sub)"$'\n'"git commit -m x" block-unresolvable
expect "cd extglob !( )"           "cd $CWD_REPO/!(sub)"$'\n'"git commit -m x" block-unresolvable

echo "── same repo, absolute literal → MUST PROCEED (no false block) ────────"
expect "cd SAME (absolute)"        "cd $CWD_REPO"$'\n'"git commit -m x"        proceed "$CWD_REPO"
expect "cd SAME subdir (absolute)" "cd $CWD_REPO/sub/dir"$'\n'"git commit -m x" proceed "$CWD_REPO"

echo "── unchanged behaviour (regression guards) ────────────────────────────"
expect "no cd at all"              "git commit -m x"                      proceed "$CWD_REPO"
# '&&'-joined stays trusted: the scope follows the cd exactly as before.
expect "cd OTHER + && (trusted)"   "cd $OTHER_REPO && git commit -m x"    proceed "$OTHER_REPO"
# `git -C` is authoritative; the parser suppresses the pending operand entirely.
expect "git -C wins over pending cd" "cd $OTHER_REPO"$'\n'"git -C $CWD_REPO commit" proceed "$CWD_REPO"
# A target that merely LOOKS like an in-band sentinel must keep its '$'-based
# unresolvable BLOCK — the reason the flag is a separate parameter (limitation 1).
# shellcheck disable=SC2016
expect "sentinel-lookalike dir + &&" 'cd "$untrusted-cd:/x" && git commit' block-unresolvable
# Omitting $3 must reproduce the pre-fix behaviour exactly — the contract the
# non-gating nudges depend on (ADR 0018 substitutes its own standalone-cd instead).
gate_resolve_repo_dir "" "$CWD_REPO"
if [ "$GATE_RESOLVE_STATUS" = "proceed" ] && [ "$GATE_REPO_DIR" = "$CWD_REPO" ]; then
    printf '  PASS  %-50s status=%s\n' "\$3 omitted → legacy cwd anchor" "$GATE_RESOLVE_STATUS"
else
    fails=$((fails + 1))
    printf '  FAIL  %-50s got=%s/%s\n' "\$3 omitted → legacy cwd anchor" \
        "$GATE_RESOLVE_STATUS" "${GATE_REPO_DIR:-<none>}"
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$fails FAILED"
exit 1
