#!/bin/bash
# Shared predicate for PASS-MERGE / empty-diff merge auto-pass (#782).
#
# An empty staged diff during a merge only proves the *tree* matches HEAD.
# `git merge -s ours <unreviewed>` keeps our tree while still making the other
# side a parent — and therefore newly reachable from the protected branch —
# without any review. Auto-pass is sound only when every MERGE_HEAD oid is
# already an ancestor of HEAD (no new reachable history).
#
# merge_heads_already_reachable <repo-dir>
#   → 0 iff MERGE_HEAD exists, is non-empty, and every listed oid is an
#     ancestor of HEAD (including equality).
#   → 1 if MERGE_HEAD is missing/empty, any oid is not an ancestor, the file
#     exceeds size/parent bounds, or git cannot decide (fail-closed).

# Bounds keep a forged MERGE_HEAD from burning the PreToolUse budget: the
# hook protocol treats timeout/no-output as allow, so unbounded per-line
# `git merge-base` would turn a flood of reachable parents into a bypass.
MERGE_HEADS_MAX_BYTES=8192
MERGE_HEADS_MAX_PARENTS=32

merge_heads_already_reachable() {
    local repo="${1:-.}"
    local mh_path parent rc any=0 size=0 parents=0

    mh_path=$(git -C "$repo" rev-parse --git-path MERGE_HEAD 2>/dev/null) || return 1
    # --git-path is relative to the -C repo; resolve before filesystem checks so a
    # gate running from another cwd does not look at the wrong .git (#782).
    case "$mh_path" in
        /*) ;;
        *) mh_path="$repo/$mh_path" ;;
    esac
    # Refuse to follow a symlinked MERGE_HEAD: the path is under .git and must
    # name the real merge-state file git wrote, not a redirected forge.
    [[ -f "$mh_path" ]] || return 1
    [[ ! -L "$mh_path" ]] || return 1
    [[ -s "$mh_path" ]] || return 1

    size=$(wc -c < "$mh_path" | tr -d '[:space:]') || return 1
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    [[ "$size" -le "$MERGE_HEADS_MAX_BYTES" ]] || return 1

    while IFS= read -r parent || [[ -n "${parent:-}" ]]; do
        [[ -z "${parent:-}" ]] && continue
        parents=$((parents + 1))
        [[ "$parents" -le "$MERGE_HEADS_MAX_PARENTS" ]] || return 1
        any=1
        rc=0
        git -C "$repo" merge-base --is-ancestor "$parent" HEAD 2>/dev/null || rc=$?
        # 0 = yes; 1 = no; >1 = git error → fail closed
        [[ "$rc" -eq 0 ]] || return 1
    done < "$mh_path"

    [[ "$any" -eq 1 ]] || return 1
    return 0
}
