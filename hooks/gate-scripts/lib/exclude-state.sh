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

# #1158: the same rules for the root .claude, in the global excludes file git reads
# for EVERY repo. Per-repo info/exclude is written only for the repos a gate or
# SessionStart sees, and a standalone `git -C <other> add -A` reaches none of them.
# Only ONE file is ever written: ~/.config/git/ignore of the account's own home (from
# the password database, not $HOME), and only while git reads it, i.e. while
# core.excludesFile (system and global config, read from / outside any repo, so
# include.path counts) is unset or names that same file. Anything else is reported
# and nothing is written: HOME, XDG_CONFIG_HOME and the GIT_CONFIG_GLOBAL/SYSTEM/
# NOSYSTEM family can come from a project settings.json `env` block, and git only
# READS the file they lead to, where this helper would append. A repo's own
# core.excludesFile replaces this file for that repo; its info/exclude rules from the
# helper above still apply there.
gate_exclude_state_global() {   # [account-home]: for tests; the hook passes none
    local home="${1:-}" want gx rc=0 d
    if [[ -z "$home" ]]; then
        home=$(python3 -I -S -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null) || home=""
    fi
    if [[ "$home" != /* || "${HOME:-}" != "$home" || -n "${GIT_CONFIG_GLOBAL+x}" || -n "${GIT_CONFIG_SYSTEM+x}" \
        || -n "${GIT_CONFIG_NOSYSTEM+x}" \
        || ( -n "${XDG_CONFIG_HOME:-}" && "$XDG_CONFIG_HOME" != "$home/.config" ) ]]; then
        echo "busdriver: git's global config is redirected (HOME, XDG_CONFIG_HOME or GIT_CONFIG_GLOBAL/SYSTEM/NOSYSTEM); .local state files in other repos stay stageable (#1158)" >&2
        return 0
    fi
    want="$home/.config/git/ignore"
    # The trailing x keeps a newline that ends the name, as in gate_exclude_state.
    # GIT_CONFIG redirects `git config` alone, and the COUNT/PARAMETERS overrides
    # last one process: none of them decides what every later session reads.
    gx=$(env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
        -u GIT_CONFIG -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
        git -C / config --path --get core.excludesFile 2>/dev/null && printf x) || rc=$?
    case "$rc" in
        0)  gx="${gx%x}"; gx="${gx%$'\n'}"
            if [[ -z "$gx" ]]; then   # set but empty: git reads no global file
                echo "busdriver: core.excludesFile is empty, so git reads no global excludes file; .local state files in other repos stay stageable (#1158)" >&2
                return 0
            fi
            if [[ "$gx" != "$want" ]]; then
                echo "busdriver: core.excludesFile names another file; busdriver writes only $want, so .local state files in other repos stay stageable (#1158)" >&2
                return 0
            fi ;;
        1)  ;;   # unset: git reads $want
        *)  echo "busdriver: could not read core.excludesFile; .local state files in other repos stay stageable (#1158)" >&2
            return 0 ;;
    esac
    # Missing directories are made one level at a time; an existing ~/.config may be
    # a dotfile manager's symlink, and the open below decides what is written.
    for d in "$home/.config" "$home/.config/git"; do
        [[ -e "$d" || -L "$d" ]] || mkdir "$d" 2>/dev/null || true
    done
    # Checked and appended through ONE descriptor, never the path twice: the file
    # opened (final symlink refused) must be a regular file with one link that this
    # account owns, so a directory swapped on the way can only lead to another file
    # of this account's own, and the block is plain ignore rules.
    gate_exclude_state_block .claude | python3 -I -S -c '
import os, stat, sys
path = sys.argv[1]
fl = os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0)
try:
    fd = os.open(path, fl)
except FileNotFoundError:
    fd = os.open(path, fl | os.O_CREAT | os.O_EXCL, 0o644)
st = os.fstat(fd)
if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_uid != os.getuid():
    sys.exit(3)
chunks = []
while True:
    c = os.read(fd, 65536)
    if not c:
        break
    chunks.append(c)
data = b"".join(chunks)
have = set(data.split(b"\n"))
missing = [l for l in sys.stdin.buffer.read().split(b"\n") if l and l not in have]
if missing:
    lead = b"\n" if data and not data.endswith(b"\n") else b""
    os.write(fd, lead + b"\n".join(missing) + b"\n")
' "$want" 2>/dev/null \
        || echo "busdriver: $want is not a regular file of this account's, or could not be written; .local state files in other repos stay stageable (#1158)" >&2
    return 0
}
