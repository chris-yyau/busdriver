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

# Escape ERE metacharacters in $1 so a literal string (e.g. $STATE_DIR) can be
# embedded in a `grep -E` pattern. Parity with Python's re.escape(), which the
# design-review DETECTOR uses on the same value — the detector and the exemption
# must treat $STATE_DIR as a literal identically or they drift out of lockstep
# (deadlock an armed review, or exempt the wrong path). Pure bash to avoid sed
# bracket-portability traps: every char outside the ERE-safe set is escaped.
# (Callers today pass an already charset-sanitized $STATE_DIR where `.` is the
# only metachar, but escaping generally keeps this correct if that ever loosens.)
gate_ere_escape() {
    local s="$1" out="" c i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9_/-]) out+="$c" ;;
            *) out+="\\$c" ;;
        esac
    done
    printf '%s' "$out"
}

# #347 — is <lexical_abspath> a design doc SAFE to exempt from the impl-block? Delegates to
# marker_ops.py `dd-exempt`, which requires the detector grammar to match BOTH the lexical
# path AND os.path.realpath (resolving EVERY symlink — leaf and parents — while keeping a
# not-yet-created tail lexical). So a symlinked parent (`docs/plans -> src`) OR a symlinked
# leaf (`docs/plans/x.md -> ../src/impl.sh`) that escapes the design-doc location is NOT
# exempt (a pending review blocks the laundered impl write), while a genuinely new doc keeps
# its lexical location and stays exempt (no deadlock). ONE implementation shared with the
# detector's grammar — no bash/python divergence. Return 0 = exempt; fail-CLOSED on error.
# Returns: 0 = exempt (a real design doc), 1 = NOT a design doc, 2 = ERROR (helper
# unavailable / unreadable / crashed). The caller MUST treat 2 as fail-CLOSED — an
# operational failure that silently read as "not a design doc" would skip arming and
# lose the review requirement (a fail-OPEN this gate exists to prevent).
# shellcheck disable=SC2034  # consumed by the sourcing gate
gate_design_doc_exempt() {   # <lexical_abspath> <state_dir>
    local lib rc
    lib="$(_gate_marker_lib_dir)" || return 2
    python3 -S "$lib/marker_ops.py" dd-exempt "$1" "$2"; rc=$?
    case "$rc" in 0|1) return "$rc" ;; *) return 2 ;; esac  # any non-0/1 → error → fail-CLOSED
}

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
    # Parentheses cover the EXTGLOB family — @(a|b), +(a), !(a), ?(a) — which expands
    # under `shopt -s extglob` / `bash -O extglob` exactly like the globs above, so
    # `cd /repo/@(other)` is not the literal directory it appears to be. A real path
    # containing parens is legal but rare, and treating it as unresolvable is the
    # fail-CLOSED direction, consistent with '{'/'[' here.
    case "$t" in
        -*|*'*'*|*'?'*|*'['*|*']'*|*'{'*|*'}'*|*'('*|*')'*) printf 'unresolvable\n'; return 0 ;;
    esac
    printf 'literal\n'
}


# Resolve REPO_DIR from the parsed target + the PreToolUse cwd field.
#
# $3 (untrusted_cd, OPTIONAL) is the cd operand that did NOT '&&'-gate the command;
# gitcmd_detect.git_commit/gh_pr surface it via with_untrusted_cd=True. ONLY the
# MARKER-SCOPED gates pass it. Omitting it preserves the previous behaviour exactly,
# which is what the non-gating nudges rely on (ADR 0018 treats such a cd as no cd and
# substitutes its own validated standalone-cd instead).
#
# Why it must be consulted: an unconfirmed `cd /other-repo` on its own line (or
# ';'-joined) usually DOES execute, so the command lands in /other-repo while this
# resolver would anchor on the payload cwd. Marker existence is the sole check, and
# both the marker and skip-*.local are $REPO_DIR-scoped, so a fresh marker or a live
# skip file in the SESSION repo would authorize an unreviewed change in /other-repo.
# We therefore proceed only when the cd PROVABLY cannot leave the cwd repo, and block
# otherwise — never guess.
#
# RESIDUAL (inherent, pre-existing, NOT introduced by the $3 check): this runs BEFORE
# the command does, so any path it resolves is a time-of-check value. A command that
# retargets its own destination mid-flight —
# `ln -sfn /other-repo /tmp/link; cd /tmp/link; git commit` — passes the same-repo
# comparison and then commits elsewhere. That is the pre-exec hook's standing limit,
# identical for the '&&'-TRUSTED path this function has always had (which resolves
# `cd /tmp/link && git commit` the same way) and for the cwd anchor itself; it is the
# same class the gates document as a `cd` shell function/alias sending the command to
# a third directory. Closing it needs a post-exec check or an exec-time sandbox, not a
# better parser. What $3 removes is the far more reachable case: an ordinary,
# non-adversarial `cd /other-repo` on its own line.
#
# Sets globals:
#   GATE_REPO_DIR        resolved repo root (or anchor); valid for proceed/outside-repo
#   GATE_RESOLVE_STATUS  proceed | outside-repo | block-unresolvable
# shellcheck disable=SC2034  # globals consumed by the sourcing gate scripts
gate_resolve_repo_dir() {
    local target="$1" hook_cwd="$2" untrusted_cd="${3:-}" kind anchor cd_root cwd_root
    kind=$(gate_classify_target "$target")

    # The parser reports an unconfirmed cd only when the resolved target is NOT
    # absolute (an absolute target alone fixes the repo). A target that is still
    # present here is therefore RELATIVE — `git -C .` after a `cd /other` — which git
    # resolves against the RUNTIME cwd while the anchor below uses the payload cwd.
    # Those two disagree and nothing static can reconcile them → block.
    if [ -n "$untrusted_cd" ] && [ "$kind" != "none" ]; then
        if [ "$kind" = "toplevel" ] && [ "$(gate_classify_target "$untrusted_cd")" = "toplevel" ]; then
            # `$(git rev-parse --show-toplevel)` IS the cwd's own repo root — but only
            # when it is the ONLY directory change. The substitution runs at EXEC time,
            # so in `cd /other; git -C "\$(git rev-parse --show-toplevel)" commit` it
            # evaluates to /other's root, not the cwd's. Requiring the unconfirmed
            # operand to be that same idiom keeps the single-cd case (which the parser
            # cannot mark authoritative, the operand not being '/'-prefixed) while
            # blocking the composed one.
            untrusted_cd=""
        else
            GATE_REPO_DIR=""
            GATE_RESOLVE_STATUS="block-unresolvable"
            return 0
        fi
    fi

    if [ "$kind" = "none" ] && [ -n "$untrusted_cd" ]; then
        # `cd "$(git rev-parse --show-toplevel)"` IS the cwd's own repo root, so it
        # cannot leave the repo however it fared — the cwd anchor already names the
        # right markers. Recognised without evaluating the substitution.
        if [ "$(gate_classify_target "$untrusted_cd")" = "toplevel" ]; then
            untrusted_cd=""
        fi
    fi

    if [ "$kind" = "none" ] && [ -n "$untrusted_cd" ]; then
        # Compare ONLY an ABSOLUTE, '..'-free, metachar-free literal — the operand
        # class _abs_cd_target()/ADR 0018 accept, for the same reasons: a RELATIVE
        # operand is subject to CDPATH (which can send `cd sub` outside the payload
        # cwd entirely), and a '..' resolves differently under bash's logical cd than
        # under the physical `git -C` used below. Neither can be compared faithfully,
        # so neither can prove confinement → block.
        case "$untrusted_cd" in
            /*) : ;;
            *) GATE_REPO_DIR=""; GATE_RESOLVE_STATUS="block-unresolvable"; return 0 ;;
        esac
        case "/$untrusted_cd/" in
            */../*) GATE_REPO_DIR=""; GATE_RESOLVE_STATUS="block-unresolvable"; return 0 ;;
        esac
        if [ "$(gate_classify_target "$untrusted_cd")" != "literal" ]; then
            GATE_REPO_DIR=""; GATE_RESOLVE_STATUS="block-unresolvable"; return 0
        fi
        # `$(...)` strips ALL trailing newlines, and a directory name may legally end
        # in one on POSIX: a repo at "/r\n" and one at "/r" both captured as "/r" and
        # compared EQUAL, so a newline-free symlink operand pointing at the former
        # slipped past the parser's newline guard and was approved as "same repo".
        # The sentinel byte keeps the strip away from the real output.
        cd_root=$(git -C "$untrusted_cd" rev-parse --show-toplevel 2>/dev/null && printf 'x' || printf '')
        cwd_root=$(git -C "${hook_cwd:-.}" rev-parse --show-toplevel 2>/dev/null && printf 'x' || printf '')
        # An EMPTY cd_root is NOT proof the cd failed — the directory may simply sit
        # outside every repo, and `gh pr merge` still resolves a PR from there (via a
        # remote or -R) even where `git commit` would not. Unprovable → block.
        if [ -z "$cd_root" ] || [ -z "$cwd_root" ] || [ "$cd_root" != "$cwd_root" ]; then
            GATE_REPO_DIR=""; GATE_RESOLVE_STATUS="block-unresolvable"; return 0
        fi
        # Same repo: wherever the cd landed, the cwd anchor names the right markers.
    fi

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

# Print <file>'s mtime in epoch seconds; non-zero when neither stat form yields
# digits (#946). Callers must BLOCK on failure: an unprovable mtime is not "old
# enough", which is what a FILE_AGE=999 default used to treat it as.
gate_file_mtime() {   # <file>
    local m
    # A form counts only if stat exits 0 AND prints digits: on GNU, `-f` means
    # filesystem, so the BSD form can print non-digits there.
    if ! { m=$(stat -f %m "$1" 2>/dev/null) && [[ $m =~ ^[0-9]+$ ]]; }; then
        { m=$(stat -c %Y "$1" 2>/dev/null) && [[ $m =~ ^[0-9]+$ ]]; } || return 1
    fi
    printf '%s\n' "$m"
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
    local f="$1" dir out
    [ -n "$f" ] || return 1
    dir="$(cd "$(dirname -- "$f")" 2>/dev/null && pwd -P)" || return 1
    [ -n "$dir" ] || return 1
    out="$dir/$(basename -- "$f")"
    # #671 — COLLAPSE a leading `//` so the single-slash spelling is the one
    # canonical key. POSIX leaves exactly-two leading slashes implementation-
    # defined and this host's bash keeps them (`cd //tmp && pwd -P` -> `//private/
    # tmp`) while python's os.path.realpath collapses them. The doc_path this
    # prints is compared for STRING EQUALITY against the python-side legacy key
    # (marker_ops _norm_legacy_doc_path), so a divergence splits one document
    # into two keys and design-clear.sh's same-document screen stops seeing the
    # other half. Collapsing on BOTH sides is the fix; making python preserve
    # `//` instead was tried during the #670 grind and reverted (it only helps
    # when both spellings are `//`, and breaks the case that works today).
    # Three-or-more slashes already collapse in both, so only `//` needs this.
    # It also fixes a pre-existing root-dir case: dirname of `/x.md` is `/`, and
    # the join above produced `//x.md` where python realpath yields `/x.md`.
    while [ "${out:0:2}" = "//" ]; do out="${out#/}"; done
    printf '%s\n' "$out"
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

# Repo-relative, symlink-resolved path of <lexical_abspath> [<anchor_dir>] —
# DELEGATES to marker_ops.py `repo-rel` (os.path.realpath + repo-relative, keeping a
# not-yet-created tail lexical). Unlike gate_marker_relpath above (which fails when
# the immediate parent dir does not yet exist and never resolves the leaf symlink),
# this walks up to the deepest existing ancestor and physically resolves every
# symlink, so a symlinked `docs/specs -> src` reads as its real location. Used by
# freeze-guard.sh to anchor its infra-exemption arms + scope check to the write's
# OWNING worktree (#375). Pass <anchor_dir> to BIND the result to the anchor's
# repository — a target in a DIFFERENT repo (or outside any repo, or realpath-
# escaped) then prints an ABSOLUTE (leading-/) path so the caller's repo-relative
# arms match none and it falls through fail-CLOSED (closes the cross-repo alias).
# Non-zero only on helper/usage failure.
# shellcheck disable=SC2034  # consumed by the sourcing gate
gate_repo_rel_phys() {   # <lexical_abspath> [<anchor_dir>]
    local lib
    lib="$(_gate_marker_lib_dir)" || return 1
    # -I (isolated), NOT -S: this resolver feeds freeze-guard's infra-exemption
    # decision, so it must ignore PYTHONPATH/PYTHONHOME and keep CWD off sys.path —
    # otherwise a shadow `subprocess.py`/`os.py` on PYTHONPATH could forge a
    # repo-relative path (e.g. `docs/specs/x`) and buy an exemption. Matches the
    # `python3 -I` the inline gate parsers already use. marker_ops.py is invoked by
    # absolute path, so -I does not disturb its import of its own trusted lib/.
    python3 -I "$lib/marker_ops.py" repo-rel "$@"
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

# #355 · Is a doc's design-reviewed PASS marker honorable? PASS present AND no
# DEGRADED coverage marker beside it — a security-gate plan must not be authorized
# on partial review coverage. DELEGATES to marker_ops.py `reviewed` so there is ONE
# implementation (no Bash/Python divergence, no two-open race, no NUL-stripping):
# python3 is already a hard dependency of every gate that sources this lib.
#   return 0 → honorable PASS; non-zero → not honored (missing/unreadable/PASS-over-DEGRADED)
gate_design_pass_honored() {
    local f="$1" lib
    [[ -f "$f" ]] || return 1
    lib="$(_gate_marker_lib_dir)" || return 1
    python3 -S "$lib/marker_ops.py" reviewed "$f"
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
    common="$(cd "$anchor" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)" || common=""
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

# ── #356 · Cross-worktree provenance for the block message ────────────────────
# The shared marker dir means a doc armed in ONE worktree blocks implementation in
# EVERY linked worktree (ADR-D, deliberate). The blast radius is repo-wide but the
# trigger is one doc in one worktree, so a blocked session sees an unrelated doc
# and misdiagnoses ("did a rogue hook delete my files?"). These helpers annotate
# each pending doc with the worktree/branch that armed it — visibility only, NO
# change to what blocks (the semantic blast-radius fix is its own design task,
# docs/plans/2026-07-12-pipeline-audit-fixes.md §A). Draining a marker armed by
# another session forges its review, so the message must name the owner, not
# invite a self-drain.

# One-line provenance suffix for a pending design doc. Empty when the doc lives in
# the SAME worktree as the blocked write (the normal plan→impl flow — no noise);
# otherwise it locates the OTHER worktree so a cross-worktree block is legible. A
# doc whose directory is gone is flagged as an abandoned marker (the drain-hint
# `rm` on the same line is then the resolution). The branch is reported as the
# owning worktree's CURRENT HEAD ("now on branch X"), NOT the branch that armed
# the token: the token is keyed only by the doc's abspath (existence-keyed, ADR-D)
# and survives branch switches, so it cannot know the arming branch. What is
# always true — and all the message needs — is that the doc is in a different
# worktree, so don't blindly drain another session's marker.
gate_marker_owner_note() {   # <doc_abspath> <self_worktree_root>
    local doc="$1" self="$2" d root branch
    [ -n "$doc" ] || return 0
    d="$(dirname -- "$doc")"
    if [ ! -d "$d" ]; then
        printf '  [doc dir missing — this marker looks abandoned]'
        return 0
    fi
    root="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$root" ] || return 0                       # not in a repo → say nothing
    # Same worktree as the write → expected case, no annotation.
    [ -n "$self" ] && [ "$root" = "$self" ] && return 0
    branch="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
        printf '  [in another worktree, now on branch %s — do not drain it unless it is abandoned]' "$branch"
    else
        printf '  [in another worktree — do not drain it unless it is abandoned]'
    fi
}

# Set the CALLER's _idx to <doc>'s position in its _doc_key array, or -1 (bash
# dynamic scoping: gate_render_pending_records owns _doc_key, _idx, _last_key and
# _last_idx). The last answer is remembered because the classifier emits each
# doc's tokens contiguously, so all but the first record of a run skip the scan.
_gate_render_key_idx() {   # <doc>
    local _s=0
    if [ "$1" = "$_last_key" ]; then _idx="$_last_idx"; return 0; fi
    _idx=-1
    while [ "$_s" -lt "${#_doc_key[@]}" ]; do
        if [ "${_doc_key[$_s]}" = "$1" ]; then _idx="$_s"; break; fi
        _s=$(( _s + 1 ))
    done
    _last_key="$1"; _last_idx="$_idx"
}

# Render the classifier's NUL records (4 fields/record: kind, source_path,
# doc_path, reason — see marker_ops.py) into the operator-facing block list,
# annotating each doc with gate_marker_owner_note. Reads records from FILE $1;
# $2 is the write's anchor (its worktree resolves "same vs other"). Echoes the
# `%b`-ready list string (literal `\n` separators, matching the callers' printf).
# Extracted from the byte-identical loops in pre-implementation-gate.sh and
# pre-commit-gate.sh so the annotation lives in ONE place and the two cannot drift.
gate_render_pending_records() {   # <recs_file> <anchor>
    local recs="$1" anchor="$2" out="" self_root clear_sh
    self_root="$(git -C "$anchor" rev-parse --show-toplevel 2>/dev/null || true)"
    # #519 item 2 — point the drain hint at the AUDITED release path, not a bare `rm`.
    # A control that forces you to destroy its own audit trail in order to proceed is
    # strictly worse for auditability than one that lets you proceed with a recorded
    # caveat. design-clear.sh (ADR 0017 / #405) clears exactly one validated token
    # after a confirm and writes a durable design-marker-cleared event; the `rm` this
    # replaces left no record at all. Resolved from THIS file's location (lib/ is
    # <root>/hooks/gate-scripts/lib) rather than $BUSDRIVER_PLUGIN_ROOT so the hint is
    # correct even when the gate runs with no plugin env set. Falls back to the old
    # `rm` hint only if the helper cannot be located — a hint that names a missing
    # script is worse than a blunt one.
    clear_sh="$(cd "$(_gate_marker_lib_dir)/../../.." 2>/dev/null && pwd -P)/scripts/design-clear.sh"
    [ -f "$clear_sh" ] || clear_sh=""
    # Escape it the same way as the doc path below. A checkout or worktree path
    # containing an apostrophe would otherwise close the single quote in the printed
    # command, so an operator (or agent) copying the hint would run something other
    # than what was intended.
    clear_sh="${clear_sh//\'/\'\\\'\'}"
    # #665 — count tokens per validated doc BEFORE rendering, so the hint names a
    # command that will actually run. Arming is per-EDIT, so a doc that went
    # through a few review rounds holds many tokens; for those the plain
    # `<doc-path>` selector REFUSES (">1 match"), and the un-counted render also
    # repeated one identical hint line per token. Emitting a guaranteed-to-fail
    # command N times at exactly the moment the backlog is largest is what pushed
    # the operator toward an unaudited `rm` in the first place. Parallel arrays +
    # linear scan, not an associative array: bash 3.2 has none.
    # _doc_n counts only VALIDATED tokens (reason == "token"); _doc_mixed marks a
    # doc that also has a non-token record. Counting every non-empty doc_path
    # would fold in legacy-pending records — a doc with one token plus a legacy
    # list-file marker would read as "2 tokens" and get hinted --all-for-doc,
    # which design-clear.sh then refuses all-or-nothing. A hint that cannot
    # succeed is the defect this whole change set out to remove, so a mixed doc
    # keeps the per-record rendering it has today.
    # #886 — the bound is on DOCUMENTS, not records. It used to be the first
    # _RCAP records, so one doc holding 20 tokens filled the window by itself,
    # every other pending doc collapsed into "… and N more pending record(s)",
    # and the one release command on offer cleared only part of the block.
    # _doc_key IS the render set: the first _RCAP distinct docs in stream order,
    # one line each (plus a line per legacy record naming them). A doc outside it
    # is counted as hidden here and skipped by the render loop.
    local _RCAP=20
    local -a _doc_key=() _doc_n=() _doc_mixed=() _doc_legacy=()
    local _hit _idx _mixed _legacy_src _cnt
    local _last_key="" _last_idx=-1 _last_hidden="" _hidden_docs=0 _extra=0 _tok_cut=0
    local _c_i=0 _c_f _c_sp="" _c_dp="" _c_reason=""
    while IFS= read -r -d '' _c_f; do
        _c_i=$((_c_i + 1))
        case $(( _c_i % 4 )) in
            2) _c_sp="$_c_f" ;;
            3) _c_dp="$_c_f" ;;
            0) _c_reason="$_c_f"
               # Scan the WHOLE stream, not the rendered window (#671 finding
               # 1): a count that describes the window rather than the doc made
               # a multi-token doc look single-token and got it hinted the plain
               # `<doc>` selector, which design-clear.sh then refuses.
               # #868 — and say when the classifier itself cut the token
               # listing: the counts are then lower bounds, not totals.
               if [ "$_c_reason" = "token-overflow" ]; then _tok_cut=1; fi
               if [ -n "$_c_dp" ]; then
                   _gate_render_key_idx "$_c_dp"
                   if [ "$_idx" -lt 0 ] && [ "${#_doc_key[@]}" -lt "$_RCAP" ]; then
                       _doc_key+=("$_c_dp"); _doc_n+=(0); _doc_mixed+=(0); _doc_legacy+=("")
                       _idx=$(( ${#_doc_key[@]} - 1 )); _last_idx="$_idx"
                   fi
                   if [ "$_idx" -lt 0 ]; then
                       # Never rendered. Valid tokens arrive grouped by doc
                       # (marker_ops sorts them), so a change of doc is one more
                       # hidden DOCUMENT; any other record counts as itself.
                       if [ "$_c_reason" != "token" ]; then
                           _extra=$(( _extra + 1 ))
                       elif [ "$_c_dp" != "$_last_hidden" ]; then
                           _hidden_docs=$(( _hidden_docs + 1 )); _last_hidden="$_c_dp"
                       fi
                   elif [ "$_c_reason" = "token" ]; then
                       _doc_n[_idx]=$(( ${_doc_n[$_idx]} + 1 ))
                   else
                       # Remember WHICH file has to be edited: for a mixed
                       # doc no design-clear selector works at all, so every
                       # line for it must point at this path instead of a
                       # command. First one wins; one actionable path beats
                       # an exhaustive list.
                       _doc_mixed[_idx]=1
                       [ -n "${_doc_legacy[$_idx]}" ] || _doc_legacy[_idx]="$_c_sp"
                   fi
               fi
               _c_sp=""; _c_dp="" ;;
        esac
    done <"$recs"
    # Records rendered one line each (legacy list entries, and the doc-less
    # unvalidated tokens, unreadable legacy files and overflow notices) get their
    # own bound, so a burst of them can never push a pending document out of the
    # message.
    local _other=0
    local _sp="" _dp="" _reason="" _i=0 _field _sp_q _dp_q _note
    while IFS= read -r -d '' _field; do
        _i=$((_i + 1))
        case $(( _i % 4 )) in
            2) _sp="$_field" ;;                      # source_path (token file)
            3) _dp="$_field" ;;                      # doc_path (validated abspath, or empty)
            0) _reason="$_field"
               if [ -n "$_dp" ]; then
                   _gate_render_key_idx "$_dp"
                   # Outside the render set: counted as hidden by the pass above.
                   if [ "$_idx" -lt 0 ]; then _sp=""; _dp=""; continue; fi
                   _hit="${_doc_n[$_idx]}"; _mixed="${_doc_mixed[$_idx]}"
                   _legacy_src="${_doc_legacy[$_idx]}"
                   # A doc's tokens render ONE line, under its first record;
                   # `_hit < 0` marks it done. Checked before the owner note,
                   # which shells out to git, so a doc's remaining tokens cost
                   # nothing here.
                   if [ "$_reason" != "legacy-pending" ] && [ "$_hit" -lt 0 ]; then
                       _sp=""; _dp=""; continue
                   fi
                   # A legacy line is one per RECORD, and the legacy backstop is
                   # L=500 — share the doc-less budget below so a long list file
                   # cannot turn this into hundreds of git calls on the 5s path.
                   if [ "$_reason" = "legacy-pending" ]; then
                       if [ "$_other" -ge "$_RCAP" ]; then
                           _extra=$(( _extra + 1 )); _sp=""; _dp=""; continue
                       fi
                       _other=$(( _other + 1 ))
                   fi
                   _note="$(gate_marker_owner_note "$_dp" "$self_root")"
                   if [ "$_reason" = "legacy-pending" ]; then
                       # A legacy list-file marker holds several docs at once, so
                       # naming IT via design-clear.sh's plain or --all-for-doc
                       # selector always refuses — releasing it would be the
                       # blanket wipe this whole tool exists to avoid (it drops
                       # every OTHER doc the list file names, not just this one).
                       # design-clear.sh's own listing already says so (cubic,
                       # PR #670); mirror that here instead of advertising a
                       # command that is guaranteed to fail.
                       # Name the list file itself rather than pointing at
                       # design-clear.sh: this branch does not depend on
                       # `$clear_sh`, so referring to that helper would send the
                       # operator to a missing script whenever it cannot be
                       # located — the exact case the fallback below exists to
                       # handle. The path is what they need either way.
                       out="${out}  - ${_dp}${_note}  [${_reason}]  (not clearable by name — edit the legacy list file: ${_sp})\n"
                   else
                       _doc_n[_idx]=-1
                       if [ "$_mixed" -eq 1 ]; then
                           # MIXED doc: a legacy entry names it AND it has tokens.
                           # NO design-clear selector works — the plain `<doc>`
                           # form matches more than one record and refuses, and
                           # --all-for-doc refuses all-or-nothing on the non-token
                           # record. Printing either is the doomed hint this
                           # renderer exists to stop emitting, so name the one
                           # action that unblocks them instead.
                           out="${out}  - ${_dp}${_note}  (not clearable while a legacy list entry names it — edit ${_legacy_src:-the legacy list file} first)\n"
                       elif [ -z "$clear_sh" ]; then
                           _sp_q="${_sp//\'/\'\\\'\'}"
                           if [ "$_hit" -gt 1 ]; then
                               # One line now stands for every token of the doc, so
                               # say how many there are. NOT a `<sha>.*` glob: that
                               # also matches unvalidated same-prefix files whose
                               # ownership the classifier never established.
                               out="${out}  - ${_dp}${_note}  (${_hit} tokens, one per edit — drain if abandoned: rm each of them, e.g. rm '${_sp_q}')\n"
                           else
                               out="${out}  - ${_dp}${_note}  (drain if abandoned: rm '${_sp_q}')\n"
                           fi
                       else
                           _dp_q="${_dp//\'/\'\\\'\'}"   # shell-escape for the hint
                           # A cut token listing (#868) makes every count a lower
                           # bound, and a doc showing 1 may hold more — so the
                           # bulk form, which works for one token too, is the
                           # only hint that cannot be refused with ">1 match".
                           _cnt="$_hit tokens"
                           if [ "$_tok_cut" -eq 1 ]; then _cnt="at least $_hit token(s)"; fi
                           if [ "$_tok_cut" -eq 1 ] || [ "$_hit" -gt 1 ]; then
                               out="${out}  - ${_dp}${_note}  (${_cnt}, one per edit — release all with an audit record each: bash '${clear_sh}' --all-for-doc '${_dp_q}')\n"
                           else
                               out="${out}  - ${_dp}${_note}  (release with an audit record: bash '${clear_sh}' '${_dp_q}')\n"
                           fi
                       fi
                   fi
               elif [ "$_other" -ge "$_RCAP" ]; then
                   _extra=$(( _extra + 1 ))
               else
                   _other=$(( _other + 1 ))
                   out="${out}  - ${_sp}  [${_reason}]\n"
               fi
               _sp=""; _dp="" ;;
        esac
    done <"$recs"
    # Say so when the listing was cut, so a bounded message is never mistaken for
    # a complete one — in DOCUMENTS first, since one release command clears one
    # doc and a hidden doc is the next block (#886). design-clear.sh (no
    # git-per-record) shows the full set.
    if [ "$_hidden_docs" -gt 0 ] || [ "$_extra" -gt 0 ]; then
        _cnt=""
        if [ "$_hidden_docs" -gt 0 ]; then
            _cnt="${_hidden_docs} more pending document(s)"
        fi
        if [ "$_extra" -gt 0 ]; then
            _cnt="${_cnt:+${_cnt} and }${_extra} more pending record(s)"
        fi
        out="${out}  - … and ${_cnt} not shown — run design-clear.sh with no args for the full listing\n"
    fi
    [ -n "$out" ] || out="  - (design review pending)\n"
    printf '%s' "$out"
}

# ── CLI dispatcher (Step 1) ───────────────────────────────────────────────────
# Side-effect-free when sourced (BASH_SOURCE[0] != $0). Direct invocation:
#   bash resolve-repo-dir.sh <norm|relpath|dir|arm|pending|sha|marker-glob|render> ARGS
# Unknown subcommand → exit 2 (fail-CLOSED for gating consumers).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _sub="${1:-}"; shift 2>/dev/null || true
    case "$_sub" in
        norm)        gate_marker_norm_path "$@" ;;
        relpath)     gate_marker_relpath "$@" ;;
        repo-rel)    gate_repo_rel_phys "$@" ;;
        dir)         gate_marker_dir "$@" ;;
        arm)         gate_marker_arm "$@" ;;
        pending)     gate_marker_pending "$@" ;;
        pending-pureshell) gate_marker_pending_pureshell "$@" ;;
        sha)         python3 -S "$(_gate_marker_lib_dir)/marker_ops.py" sha "$@" ;;
        marker-glob) gate_marker_glob "$@" ;;
        render)      gate_render_pending_records "$@" ;;
        *)           exit 2 ;;
    esac
    exit $?
fi
