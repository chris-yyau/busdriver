#!/usr/bin/env bash
# Shared repo-directory resolution for PreToolUse git gates
# (pre-commit-gate.sh, pre-pr-gate.sh, pre-merge-gate.sh).
#
# WHY: each gate must decide which repo's marker/lock files to read. It used to
# derive that purely from a regex `cd <dir>` parse of the command string.
# Command substitution (cd "$(git rev-parse --show-toplevel)") defeats the
# regex: the literal substitution becomes a bogus path, `git -C "$bogus"` fails,
# and the old `|| exit 0` ("not in a repo -> approve") branch then SILENTLY
# APPROVED the commit/PR with no review (fail-OPEN in pre-pr/pre-commit).
# pre-merge instead blocked on a missing marker (fail-closed, but a spurious
# block).
#
# FIX: anchor on the PreToolUse `cwd` field (the authoritative directory the
# Bash command runs in -- see skills/continuous-learning-v2/hooks/observe.sh for
# prior art), and treat the parsed cd target only as a refinement.
# Single source of truth so the three gates cannot drift apart again.

# Classify a (quote-stripped, ~-expanded) cd/-C target string.
# Echoes one of: none | literal | toplevel | unresolvable
gate_classify_target() {
    local t="$1"
    [ -z "$t" ] && { printf 'none\n'; return 0; }
    # Recognized safe idiom: the whole value is $(git rev-parse --show-...) or
    # its backtick form -- equivalent to the cwd's repo root, so the cwd anchor
    # resolves it faithfully without evaluating the substitution. The two
    # alternatives are each fully anchored so a mismatched-delimiter input
    # (e.g. $(...`) cannot match.
    # SC2016: the $(/backtick literals are the patterns we match, not expansions.
    # shellcheck disable=SC2016
    if printf '%s' "$t" | grep -Eq '^\$\(git rev-parse --show-(toplevel|cdup)\)$|^`git rev-parse --show-(toplevel|cdup)`$'; then
        printf 'toplevel\n'; return 0
    fi
    # ANY dollar expansion or backtick is opaque to a static parser ->
    # unresolvable (caller fails CLOSED). This includes bare $VAR (cd $PWD,
    # cd $HOME): the gate cannot know where it points, and at shell runtime it
    # may be a no-op that lands the op in the live repo unreviewed. The bare
    # `$` arm subsumes $( and ${; the toplevel idiom already returned above.
    # shellcheck disable=SC2016
    case "$t" in
        *'$'*|*'`'*) printf 'unresolvable\n'; return 0 ;;
    esac
    # Other shell-active forms cause the same static-vs-runtime divergence as
    # $-expansion: `cd -` jumps to $OLDPWD, globs (cd *, cd foo?) and brace
    # expansion (cd {a,b}) succeed at runtime landing the op in a real repo,
    # but as static strings they are not the path the command actually uses.
    # Any leading-dash form is a cd option/separator the shell strips before
    # changing directory (`cd -`, `cd --`, `cd -- /repo`, `cd -L/-P/-e/-@ /repo`)
    # so the recorded string is not where the op runs. Fail-CLOSED on all of
    # them. (Not a security boundary: wrapper forms the regex never sees --
    # `bash -c "..."`, `(cd X && ...)` subshells, `pushd`, backslash-escaped
    # paths -- remain a documented residual; the goal is to close
    # common/accidental skips, not to reimplement a shell. See the council
    # lesson and PR description.)
    case "$t" in
        -*|*'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*) printf 'unresolvable\n'; return 0 ;;
    esac
    printf 'literal\n'
}

# Resolve REPO_DIR from the parsed target + the PreToolUse cwd field.
# Sets globals:
#   GATE_REPO_DIR        resolved repo root (or anchor); valid for proceed/outside-repo
#   GATE_RESOLVE_STATUS  proceed | outside-repo | block-unresolvable
# shellcheck disable=SC2034  # globals consumed by the sourcing gate scripts
gate_resolve_repo_dir() {
    local target="$1" hook_cwd="$2" kind anchor
    kind=$(gate_classify_target "$target")

    if [ "$kind" = "unresolvable" ]; then
        GATE_REPO_DIR=""
        GATE_RESOLVE_STATUS="block-unresolvable"
        return 0
    fi

    if [ "$kind" = "literal" ]; then
        # Resolve a RELATIVE literal against the authoritative cwd field, not the
        # hook process CWD (which may differ from where the command runs).
        # Absolute targets are used as-is.
        case "$target" in
            /*) anchor="$target" ;;
            *)  anchor="${hook_cwd:-.}/$target" ;;
        esac
    else
        # none | toplevel -> authoritative cwd, falling back to the hook process
        # CWD when the field is absent (older clients).
        anchor="${hook_cwd:-.}"
    fi

    GATE_REPO_DIR=$(git -C "$anchor" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$anchor")

    if git -C "$GATE_REPO_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        GATE_RESOLVE_STATUS="proceed"
    else
        GATE_RESOLVE_STATUS="outside-repo"
    fi
}

# Best-effort repo-dir resolution for POST hooks (marker consume / cleanup) --
# echoes a repo root and NEVER blocks. Post hooks fire only AFTER a command ran,
# so the pre-gate has already blocked the truly-unresolvable forms ($VAR, cd -,
# globs); a post hook therefore only sees literal / toplevel / none targets.
# This mirrors the pre-gate's cwd-anchored resolution so the pre-gate and its
# paired post hook agree on WHICH repo holds the .claude/ markers -- otherwise
# the toplevel form (cd "$(git rev-parse --show-toplevel)") would be approved
# against the real repo but its marker looked up under the literal junk path,
# leaving a stale marker behind. Defensively, an unresolvable target still
# falls back to the cwd anchor rather than the junk literal.
gate_repo_dir_lenient() {
    local target="$1" hook_cwd="$2" kind anchor
    kind=$(gate_classify_target "$target")
    if [ "$kind" = "literal" ]; then
        case "$target" in
            /*) anchor="$target" ;;
            *)  anchor="${hook_cwd:-.}/$target" ;;
        esac
    else
        # none | toplevel | unresolvable -> the authoritative cwd anchor.
        anchor="${hook_cwd:-.}"
    fi
    git -C "$anchor" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$anchor"
}

# Return 0 (== "repo-controlled → do NOT honor as a skip signal") iff the skip
# file at <repo_root>/<repo_relative_path> is tracked by git — present in the
# index or HEAD, or sitting in a gitlinked/submodule state dir. A `.claude/*.local`
# skip file is only real OPERATOR consent when it is UNtracked: `.gitignore`
# prevents an accidental `git add`, but NOT `git add -f`, so a malicious PR can
# commit a skip file that (after checkout, past the 30s age window) would bypass
# the gate. This is the same committable-content injection class as issue #325.
# FAIL-CLOSED: any git error returns 0 (reject the skip). Mirrors the vetted
# `_repo_controlled` resolver in scripts/advisory-downgrade-optin.sh.
# shellcheck disable=SC2034  # consumed by the sourcing gate scripts
gate_skip_file_repo_controlled() {   # <repo_root> <repo_relative_path>
    local root="$1" rel="$2" dir_rel stage tracked
    [ -z "$root" ] && return 0
    dir_rel=$(dirname "$rel")
    stage=$(git -C "$root" ls-files --stage -- "$dir_rel" 2>/dev/null) || return 0
    grep -q '^160000 ' <<<"$stage" && return 0          # gitlink/submodule state dir
    # Parent dir tracked as a symlink (mode 120000): git resolves `.claude/skip-*.local`
    # behind an attacker-committed `.claude` symlink that the leaf-path ls-files/cat-file
    # checks below never see. Reject — same committable-injection class as #325.
    awk -v p="$dir_rel" '$1=="120000" && $4==p {f=1} END{exit !f}' <<<"$stage" && return 0
    tracked=$(git -C "$root" ls-files -- "$rel" 2>/dev/null) || return 0
    [ -n "$tracked" ] && return 0                        # in the index
    # Is <rel> in HEAD's tree? `ls-tree` (pathspec relative to the -C dir, matching the
    # ls-files check above) distinguishes the three outcomes `cat-file -e` conflates:
    #   rc==0, entry set   → present in HEAD's tree                       → reject
    #   rc==0, entry empty → every tree on the path readable, file absent → honor
    #   rc!=0              → a tree/subtree needed to resolve <rel> is unreadable (root OR
    #                        nested corruption) — OR the repo is unborn. Discriminate below.
    # This is why `cat-file -e "HEAD:<rel>"` / `HEAD^{tree}` are insufficient: the former
    # can't tell "absent" from "unreadable", and the latter only proves the ROOT tree
    # exists, missing corruption of a nested subtree (e.g. `.claude/`) on the path.
    local head_entry rc
    head_entry=$(git -C "$root" ls-tree HEAD -- "$rel" 2>/dev/null); rc=$?
    if [ "$rc" -eq 0 ]; then
        [ -n "$head_entry" ] && return 0                 # in HEAD's tree → reject
        return 1                                         # readable trees, file absent → honor
    fi
    # ls-tree errored: corrupt/unreadable tree object, or unborn HEAD. `rev-parse --verify
    # HEAD` is 0 for a dangling/corrupt ref (sha resolves syntactically) but 1 for unborn —
    # so it cleanly splits "corrupt → fail CLOSED" from "unborn → honor".
    git -C "$root" rev-parse -q --verify HEAD >/dev/null 2>&1 && return 0   # corrupt tree → fail CLOSED
    return 1                                                                # unborn repo → honor
}
