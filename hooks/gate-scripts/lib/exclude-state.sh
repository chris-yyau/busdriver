# shellcheck shell=bash
# #1147: keep busdriver's own state out of user commits. The gates and skills write
# into <repo>/<STATE_DIR>/ before the gated command runs, so in a repo whose
# .gitignore does not list those files, `git add -A && git commit` stages them.
# Listing them in the repo's info/exclude (shared by every linked worktree, never
# committed, never stageable) hides them from `git add` without moving any state.
# Tracked files are unaffected: an exclude rule only hides UNtracked paths, so the
# tracked-skip-file rejection in resolve-repo-dir.sh reads the same index as before.
# The list mirrors busdriver's own .gitignore state block, and
# tests/test-gate-state-exclude.sh fails when the two drift apart.
#
# Hygiene, not enforcement: it never blocks and never fails its caller. A failure is
# reported on stderr and costs only the old behaviour (files stageable).

# Print the exclude block for state dir $1 (already sanitized by the caller).
gate_exclude_state_block() {
    local sd="$1" p
    printf '# busdriver gate state: /%s/ (#1147, added automatically)\n' "$sd"
    for p in '*.local' '*.local.*' 'litmus-state.md' 'litmus-review.lock' \
        'litmus-review.lock.probe.*' 'bypass-log.jsonl' 'review-metrics.jsonl' '*.log' \
        '_backstop/' 'ultra-oracle/' 'oracle-max/' 'builtin-review-*.hash'; do
        printf '/%s/%s\n' "$sd" "$p"
    done
}

# Add whichever lines of the block are missing to the info/exclude of the repo
# containing $1. Checking every line, not just the header, repairs an interrupted
# append and gives existing repos the rules a later release adds.
# With a third argument `literal`, $2 is a repo-relative path as git reports it
# (a subdirectory's .claude) rather than a gate's state dir: no gate fallback,
# any name but a control character or a `..` component, glob characters escaped.
gate_exclude_state() {   # <dir-in-repo> <state_dir> [literal]
    local dir="$1" sd="$2" ex
    if [[ "${3:-}" == literal ]]; then
        case "$sd" in ""|/*|..|../*|*/..|*/../*|*[[:cntrl:]]*) return 0 ;; esac
    else
        # The fallback every gate applies, on the spelling the gates see.
        case "$sd" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) sd=".claude" ;; esac
    fi
    # Reduce it to the path git reports (the gates accept ./x, .//x, x//y, x/, x/.).
    # Doubled slashes go first, so a leading ./ is never stripped down to an
    # absolute-looking remainder.
    while :; do
        case "$sd" in
            *//*) sd="${sd//\/\//\/}" ;;
            ./*) sd="${sd#./}" ;;
            */./*) sd="${sd/\/.\//\/}" ;;
            */) sd="${sd%/}" ;;
            */.) sd="${sd%/.}" ;;
            *) break ;;
        esac
    done
    # State at the repo root: rules for /*.log and the like would hide the user's
    # own files, so nothing is added there.
    case "$sd" in ""|.) return 0 ;; esac
    # Only a single dot-named directory at the root (.claude, .bd): the override can
    # come from a repo's committed settings.json `env` block, and rules for src/ or
    # .config/src/ would hide that repo's own files.
    if [[ "${3:-}" != literal ]]; then
        case "$sd" in */*|..*) return 0 ;; .?*) ;; *) return 0 ;; esac
    fi
    # A literal name may hold characters git reads as glob syntax.
    if [[ "${3:-}" == literal ]]; then
        sd=${sd//\\/\\\\}; sd=${sd//\*/\\*}; sd=${sd//\?/\\?}; sd=${sd//\[/\\[}
    fi
    # Built from the common dir rather than --git-path, which resolves a symlinked
    # exclude to its target and so hides it from the check below.
    # The trailing x keeps a newline that ends the dir name ($( ) strips them all);
    # only git's own line end is then removed.
    # An inherited GIT_DIR (SessionStart runs in the session's environment) would
    # name another repo than the one $dir is in.
    ex=$(env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
        git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null && printf x) \
        || return 0   # not a repo: nothing to protect
    ex="${ex%x}"; ex="${ex%$'\n'}/info/exclude"
    # Only a plain file of this repo: a symlink or a second hard link could be another
    # repo's ignore list, and reading a FIFO would hang the hook. (Whoever can swap
    # files inside the git dir between this check and the append already controls
    # the repo.)
    local links=1
    if [[ -e "$ex" ]]; then
        # GNU first: GNU `stat -f %l` succeeds too, printing a filesystem limit.
        links=$(stat -c %h "$ex" 2>/dev/null) || links=$(stat -f %l "$ex" 2>/dev/null) || links=""
    fi
    if [[ -L "$ex" || -L "$(dirname "$ex")" || ( -e "$ex" && ! -f "$ex" ) || "$links" != 1 ]]; then
        echo "busdriver: $ex is not a regular file; .local state files there stay stageable (#1147)" >&2
        return 0
    fi
    local missing rc=0
    if [[ -f "$ex" ]]; then
        # grep -v: 0 = some lines missing, 1 = all present, 2 = unreadable.
        missing=$(gate_exclude_state_block "$sd" | grep -vxF -f "$ex") || rc=$?
        if [[ "$rc" -gt 1 ]]; then
            echo "busdriver: could not read $ex; .local state files there may stay stageable (#1147)" >&2
            return 0
        fi
    else
        missing=$(gate_exclude_state_block "$sd")
    fi
    [[ -n "$missing" ]] || return 0
    # Appended, never rewritten: an append cannot drop another hook's concurrent
    # update (linked worktrees share this file) and keeps the file's inode, mode,
    # ACLs and any leading BOM. Two hooks racing can add the same line twice, which
    # is harmless. Being last, these rules outrank an earlier `!` line in this
    # file: an exception for a busdriver state file belongs in .gitignore, which
    # outranks info/exclude. (Re-appending the user's own rules after ours was
    # tried and cannot reproduce git's precedence in general, so it is not done.)
    # A last line without its newline would swallow the first added line.
    if ! { mkdir -p "$(dirname "$ex")" \
        && { [[ ! -s "$ex" ]] || [[ -z "$(tail -c 1 "$ex")" ]] || echo >> "$ex"; } \
        && printf '%s\n' "$missing" >> "$ex"; } 2>/dev/null; then
        echo "busdriver: could not add gate state to $ex; .local state files there stay stageable (#1147)" >&2
    fi
    return 0
}
