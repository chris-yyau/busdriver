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

# ═════════════════════════════════════════════════════════════════════════════
# Task 2 — worktree-safe design-review marker (immutable per-arming tokens).
# Replaces the single CWD-relative `design-review-needed.local.md` with a
# directory of EXISTENCE-keyed tokens under the shared git-common-dir, so a doc
# armed in one worktree blocks commits/impl writes in every linked worktree.
# Design: docs/plans/2026-07-13-task2-worktree-design-marker.md (ADR-A..E, §5).
# ═════════════════════════════════════════════════════════════════════════════

# Directory holding THIS file (the trusted gate lib/). Recomputed per call so
# sourcing has NO side effects; ${BASH_SOURCE[0]} is always resolve-repo-dir.sh.
_gate_marker_lib_dir() { cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P; }

# Sanitized harness state dir (mirror the gates) — decouples the CLI/classifier
# from the caller having STATE_DIR set.
_gate_marker_state_dir() {
    local sd="${BUSDRIVER_STATE_DIR:-.claude}"
    case "$sd" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) sd=".claude" ;; esac
    printf '%s\n' "$sd"
}

# ADR-B · Physical absolute path = the token GROUP KEY. Non-zero if the parent
# dir can't be resolved (deleted/unreadable/not-yet-created) → §2 best-effort miss.
gate_marker_norm_path() {
    local f="$1" dir
    [ -n "$f" ] || return 1
    dir="$(cd "$(dirname -- "$f")" 2>/dev/null && pwd -P)" || return 1
    [ -n "$dir" ] || return 1
    printf '%s/%s\n' "$dir" "$(basename -- "$f")"
}

# Repo-relative path of <path> within its OWNING worktree — for the ADR-B
# structural-dir exclusion and the ADR-E allowlist ONLY (never the token key).
# Non-zero if not inside a repo, or the file escapes the resolved root.
gate_marker_relpath() {
    local f="$1" d root abs
    [ -n "$f" ] || return 1
    d="$(dirname -- "$f")"
    root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || return 1
    [ -n "$root" ] || return 1
    root="$(cd "$root" 2>/dev/null && pwd -P)" || return 1
    abs="$(cd "$d" 2>/dev/null && pwd -P)" || return 1
    abs="$abs/$(basename -- "$f")"
    case "$abs" in
        "$root"/*) printf '%s\n' "${abs#"$root"/}" ;;
        *) return 1 ;;
    esac
}

# ADR-A · The shared marker directory <git-common-dir>/busdriver/…local.d/.
# Exit 0 = resolved (path on stdout); 3 = ENOREPO carve-out (§5 — not inside a
# work tree; caller ALLOWs, matching today); 1 = in-repo but common-dir
# unresolvable (caller BLOCKs fail-CLOSED).
gate_marker_dir() {
    local anchor="${1:-.}" inwt common
    inwt="$(git -C "$anchor" rev-parse --is-inside-work-tree 2>/dev/null || true)"
    [ "$inwt" = "true" ] || return 3
    common="$(cd "$anchor" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || return 1
    [ -n "$common" ] || return 1
    printf '%s/busdriver/design-review-needed.local.d\n' "$common"
}

# ADR-D · Arm a doc: best-effort create-only token. Non-zero on any miss (§2).
gate_marker_arm() {
    local doc="$1" norm dir lib
    norm="$(gate_marker_norm_path "$doc")" || return 1
    dir="$(gate_marker_dir "$(dirname -- "$norm")")" || return 1
    lib="$(_gate_marker_lib_dir)" || return 1
    python3 -S "$lib/marker_ops.py" arm "$dir" "$norm"
}

# ADR-C · Existence-keyed classifier + bounded legacy union. Mandatory anchor.
# Streams NUL records on stdout. Exit 0 = none pending; 1 = pending; 2 = failure.
gate_marker_pending() {
    local anchor="$1" dir st=0 lib sd
    [ -n "$anchor" ] || return 2
    # `|| st=$?` (not `; st=$?`): a failing command-substitution assignment trips
    # `set -e` in the sourcing gates before the next line runs — the OR-list form
    # suppresses that and captures the code.
    dir="$(gate_marker_dir "$anchor")" || st=$?
    case "$st" in
        0) : ;;
        3) return 0 ;;   # ENOREPO → allow (no marker to consult)
        *) return 2 ;;   # in-repo unresolvable → block (fail-CLOSED)
    esac
    lib="$(_gate_marker_lib_dir)" || return 2
    sd="$(_gate_marker_state_dir)"
    python3 -S "$lib/marker_ops.py" classify "$dir" "$anchor" "$sd"
}

# Pure-shell existence probe — no python3. Two uses: (1) the read gates' hot-path
# fast reject (the common "nothing pending" case, so a benign edit doesn't fork
# python3), and (2) the python3-MISSING degraded path (the classifier needs
# python3). Exit 0 = nothing pending / ENOREPO (allow); 1 = pending OR in-repo but
# common-dir unresolvable (caller blocks fail-CLOSED). It does NOT parse legacy
# PASS markers — a bare-existing legacy marker returns 1, so the authoritative
# gate_marker_pending must run next to decide reviewed-vs-pending. Anchor → CWD.
gate_marker_pending_pureshell() {
    local anchor="${1:-.}" inwt common tokdir sd root line wt _e
    inwt="$(git -C "$anchor" rev-parse --is-inside-work-tree 2>/dev/null || true)"
    [ "$inwt" = "true" ] || return 0   # ENOREPO → allow (matches today)
    common="$(cd "$anchor" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P || true)"
    [ -n "$common" ] || return 1       # in a repo, common-dir unresolvable → uncertain
    tokdir="$common/busdriver/design-review-needed.local.d"
    # CONTRACT: return 0 ONLY when definitively clean. Any error/ambiguity → return
    # 1, so the read gate falls through to the authoritative classifier (which
    # returns exit 2 = block) and the python3-missing path blocks fail-CLOSED. A
    # listing error, a non-directory at the marker path, or a worktree-enumeration
    # failure must NEVER read as "empty" (would disable enforcement — litmus HIGH).
    # `-e || -L`: a DANGLING symlink is false under `-e` but is anomalous marker
    # state, not "absent" — treat it as uncertain (→ authoritative → fail-CLOSED).
    if [ -e "$tokdir" ] || [ -L "$tokdir" ]; then
        [ -d "$tokdir" ] || return 1                 # not a dir (incl. dangling symlink)
        # Need BOTH read (to list) and search/execute (to stat entries via the glob
        # below). A dir readable-but-not-searchable would list names yet make every
        # `[ -e ]` stat fail → the glob loop would miss real tokens and fast-allow.
        { [ -r "$tokdir" ] && [ -x "$tokdir" ]; } || return 1
        ls -A "$tokdir" >/dev/null 2>&1 || return 1  # listing error → uncertain
        # Detect ANY entry via GLOBBING, never `$(ls)` — a filename made entirely
        # of newline bytes survives command substitution's trailing-newline strip
        # and would read as "empty" (fast allow); a glob never serializes the name.
        for _e in "$tokdir"/* "$tokdir"/.[!.]* "$tokdir"/..?*; do
            { [ -e "$_e" ] || [ -L "$_e" ]; } || continue   # skip non-matching glob patterns
            return 1                                         # >=1 entry present
        done
    fi
    sd="$(_gate_marker_state_dir)"
    if ! wt="$(git -C "$anchor" worktree list --porcelain 2>/dev/null)"; then
        return 1                                     # worktree enumeration failed
    fi
    while IFS= read -r line; do
        case "$line" in
            'worktree "'*)                           # C-quoted path (newline/quote/backslash in it):
                return 1 ;;                           # can't parse safely here → NUL-aware classifier
            'worktree '*)
                root="${line#worktree }"
                if [ -e "$root/$sd/design-review-needed.local.md" ] || [ -L "$root/$sd/design-review-needed.local.md" ]; then
                    return 1                         # a legacy marker exists (bounded per-root)
                fi ;;
        esac
    done < <(printf '%s\n' "$wt")
    return 0
}

# Loop prune helper (ADR-D): print "<marker-dir>/<sha(norm(doc))>." prefix. The
# review loop snapshots `${prefix}*` at start and `rm -f`s exactly that on PASS.
gate_marker_glob() {
    local doc="$1" norm dir sha lib
    norm="$(gate_marker_norm_path "$doc")" || return 1
    dir="$(gate_marker_dir "$(dirname -- "$norm")")" || return 1
    lib="$(_gate_marker_lib_dir)" || return 1
    sha="$(python3 -S "$lib/marker_ops.py" sha "$norm")" || return 1
    printf '%s/%s.\n' "$dir" "$sha"
}

# ── CLI dispatcher (Step 1) ───────────────────────────────────────────────────
# Side-effect-free when sourced (BASH_SOURCE[0] != $0). Direct invocation:
#   bash resolve-repo-dir.sh <norm|relpath|dir|arm|pending|sha|marker-glob> ARGS
# Unknown subcommand → exit 2 (fail-CLOSED for gating consumers).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _sub="${1:-}"; shift 2>/dev/null || true
    case "$_sub" in
        norm)        gate_marker_norm_path "$@" ;;
        relpath)     gate_marker_relpath "$@" ;;
        dir)         gate_marker_dir "$@" ;;
        arm)         gate_marker_arm "$@" ;;
        pending)     gate_marker_pending "$@" ;;
        pending-pureshell) gate_marker_pending_pureshell "$@" ;;
        sha)         python3 -S "$(_gate_marker_lib_dir)/marker_ops.py" sha "$@" ;;
        marker-glob) gate_marker_glob "$@" ;;
        *)           exit 2 ;;
    esac
    exit $?
fi
