#!/usr/bin/env bash
# Shared guard: is a gate skip file OPERATOR-OWNED (safe to honor), or
# REPO-CONTROLLED (a committed / injected file the PR under review could plant)?
#
# Closes the residual settings.json-injection vector left after the SKIP_* env
# hatches were removed (issue #325 / ADR 0016): a PR can commit a tracked skip
# file — directly (`git add -f .claude/skip-litmus.local`) or by redirecting
# BUSDRIVER_STATE_DIR at a tracked dir (`evil/skip-litmus.local`) — that the gate
# would otherwise consume and exit 0 before review. Any PR-delivered file is
# git-tracked, so rejecting repo-controlled skip files closes the vector by
# construction. Mirrors the hardened repo-controlled check in
# scripts/advisory-downgrade-optin.sh (ADR 0012).
#
# skip_file_operator_owned <repo_root> <state_dir> <filename>
#   Returns 0 iff the skip file exists AND is operator-owned: a non-symlink
#   REGULAR file, in a non-symlink / non-gitlink state dir whose name is a plain
#   single component, that is NOT repo-controlled (not in the index, not in
#   HEAD's tree). Returns 1 otherwise (missing OR repo-controlled OR any git
#   error → FAIL-CLOSED: do not honor). Runs its checks in a subshell so the
#   git-env scrub does not leak into the caller.

# Return 0 (== repo-controlled, REJECT) iff the state dir is a gitlink/submodule
# (mode 160000), OR the file is in the index, OR present in HEAD's tree.
# FAIL-CLOSED: any git error returns 0 (reject). Returns 1 only when provably none hold.
_skip_guard_repo_controlled() {   # <marker_path> <repo_root>
    local path="$1" root="$2" rel dir_rel stage tree_dir tracked _tree
    rel="${path#"${root%/}"/}"
    dir_rel=$(dirname "$rel")
    # Gitlink / submodule state dir → reject. Check BOTH the index AND HEAD: a
    # gitlink committed in HEAD but dropped from the index would pass an
    # index-only check, and `ls-tree` of the FILE path returns empty because git
    # does not traverse into a gitlink — so an aged file in the submodule
    # checkout would be wrongly honored. Fail CLOSED on any git error.
    stage=$(git -C "$root" ls-files --stage -- "$dir_rel" 2>/dev/null) || return 0
    grep -q '^160000 ' <<<"$stage" && return 0
    tree_dir=$(git -C "$root" ls-tree HEAD -- "$dir_rel" 2>/dev/null) || return 0
    grep -q '^160000 ' <<<"$tree_dir" && return 0
    # Present in the index → reject.
    tracked=$(git -C "$root" ls-files -- "$rel" 2>/dev/null) || return 0
    [[ -n "$tracked" ]] && return 0
    # Present in HEAD's committed tree → reject. `git ls-tree HEAD` positively
    # proves ABSENCE only on exit 0 with EMPTY output (non-empty = present →
    # reject). ANY non-zero exit — a real git error OR an unborn repo with no
    # HEAD commit — cannot prove absence, so `|| return 0` FAILS CLOSED (reject).
    # This avoids guessing whether a nonzero rev-parse/cat-file exit means
    # "absent" or "error": git conflates the two and the codes vary by corruption
    # mode (verified: cat-file -e on a missing path exits 128, not 1). The only
    # cost is a zero-commit repo won't honor a skip file — a non-scenario for
    # gates that review commit history.
    _tree=$(git -C "$root" ls-tree HEAD -- "$rel" 2>/dev/null) || return 0
    [[ -n "$_tree" ]] && return 0
    return 1
}

skip_file_operator_owned() {   # <repo_root> <state_dir> <filename>
    local root="$1" state="$2" fname="$3"
    # Reject an empty / traversal / multi-component state dir: a repo-injected
    # BUSDRIVER_STATE_DIR=alias/.claude (with `alias` a tracked symlink dir)
    # could otherwise slip a repo-controlled file past the lexical checks. The
    # gates' own STATE_DIR sanitizer permits `/`; the skip-honoring path is stricter.
    case "$state" in ''|.|..|*/*) return 1 ;; esac
    # The subshell contains the git-env scrub; normalize its exit to 0 (honor) /
    # 1 (reject) so a git error's raw exit (e.g. 128) cannot leak as the return.
    if (
        # Neutralize repo-supplied git-env injection so every git query below
        # discovers the repo purely from <root> (which the caller pins to the
        # gate's own REPO_DIR). Contained in this subshell.
        unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
              GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
              GIT_NAMESPACE GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_COUNT 2>/dev/null || true
        local ppath pdir
        ppath="${root%/}/${state}/${fname}"
        pdir="${root%/}/${state}"
        [[ -f "$ppath" ]] && [[ ! -L "$ppath" ]] && [[ ! -L "$pdir" ]] \
            && git -C "$root" rev-parse --git-dir >/dev/null 2>&1 \
            && ! _skip_guard_repo_controlled "$ppath" "$root"
    ); then
        return 0
    fi
    return 1
}
