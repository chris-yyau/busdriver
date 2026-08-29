#!/usr/bin/env bash
# scripts/lib/exclusion-integrity.sh — integrity guards for the review-exclusion
# inputs that an excluded-only auto-pass depends on.
#
# WHY THIS IS SHARED (#576 item 3). An excluded-only auto-pass asserts "there is
# nothing here a reviewer needs to see". Two inputs decide that:
#   1. the POLICY  — $STATE_DIR/review-exclude (the patterns), and
#   2. the LOGIC   — skills/litmus/scripts/lib/exclude-generated.sh, which parses
#                    the policy, adds its hardcoded defaults, and builds
#                    REVIEW_EXCLUDE_ARGS.
# dispatcher-commit-block.sh has guarded BOTH since #280/#281. The producer
# (run-review-loop.sh) guarded only the policy, so an in-worktree edit to the LOGIC
# widened exclusions exactly the way a widened policy would — and the marker minted
# afterwards was *correctly* hash-bound to a diff no reviewer ever saw. Duplicating
# ~90 lines of this into the producer would reproduce the failure mode #576 is
# about (N copies that must agree and eventually don't), so it lives here once.
#
# WHY scripts/lib/ AND NOT skills/litmus/scripts/lib/. This code validates
# exclude-generated.sh. Housing the validator in the same directory as its target
# would mean one uncommitted edit under skills/litmus/scripts/lib/ could disable the
# guard AND widen the exclusions in a single move. Keeping it in the dispatcher's
# own lib dir preserves the separation. (For the producer the placement is moot —
# anyone able to edit that dir could edit run-review-loop.sh itself — but for the
# dispatcher it is load-bearing.)
#
# CONTRACT. Callers get a boolean plus globals, so each maps failure onto its own
# idiom (the dispatcher's emit_bail envelope, the producer's terminal-status exit):
#   verify_exclusion_logic <worktree_dir> <litmus_scripts_dir>
#     returns 0 → EXCL_LOGIC_SOURCE is the validated, collapsed path to source.
#     returns 1 → EXCL_LOGIC_ERROR holds the reason and EXCL_LOGIC_ERROR_KIND is
#                 "judgment" (refused) or "env" (could not determine ⇒ still refuse).
# Fail CLOSED throughout: every probe error is a refusal, never a skip.

# These three ARE the return channel — read by callers after the functions below,
# never within this file, which is exactly what SC2034 flags.
# shellcheck disable=SC2034
EXCL_LOGIC_SOURCE=""
# shellcheck disable=SC2034
EXCL_LOGIC_ERROR=""
# shellcheck disable=SC2034
EXCL_LOGIC_ERROR_KIND=""
# Set when verify_exclusion_logic materialised HEAD's blob; the caller unlinks it
# after sourcing.
# shellcheck disable=SC2034
EXCL_LOGIC_PINNED_TMP=""
# Set when verify_exclusion_policy materialised HEAD's blob for the policy file.
# shellcheck disable=SC2034
EXCL_POLICY_SOURCE=""
# shellcheck disable=SC2034
EXCL_POLICY_PINNED_TMP=""

_excl_fail() {
    EXCL_LOGIC_ERROR_KIND="$1"
    EXCL_LOGIC_ERROR="$2"
    return 1
}

# Collapse "..", "." and duplicate "/" PURELY LEXICALLY — string manipulation only,
# no filesystem access, so unlike realpath/`pwd -P` it cannot be fooled by a symlink
# swap. A relative LITMUS_SCRIPTS containing ".." (e.g. `../external-plugin/scripts`,
# a legitimate trusted-external plugin root) would otherwise string-prefix-match the
# worktree even though it escapes it, making the guard run `git status` on a bogus
# out-of-repo pathspec and fail-close every excluded-only commit for that trusted
# case (Cursor/Cubic, PR #280).
exclusion_lexical_collapse() {
    local _path="$1" _out="" _s _parts
    # Split on "/" WITHOUT pathname (glob) expansion. An unquoted array assignment
    # `_parts=($_path)` under IFS=/ ALSO globs each segment, so a "*"/"?"/"[" in the
    # worktree or scripts path would expand against the filesystem and normalize to
    # the wrong path (litmus, PR #280). `read -ra` word-splits on IFS only. The
    # `IFS=/` prefix scopes IFS to the read builtin — no save/restore needed.
    IFS=/ read -r -a _parts <<< "$_path"
    for _s in "${_parts[@]}"; do
        case "$_s" in
            ""|".") continue ;;
            "..") _out="${_out%/*}" ;;
            *) _out="$_out/$_s" ;;
        esac
    done
    [[ -z "$_out" ]] && _out="/"
    printf '%s' "$_out"
}

# Reject an UNTRUSTED path component (committed symlink OR gitlink/submodule) at ANY
# in-worktree component — leaf OR parent dir — of a path whose bytes we are about to
# trust:
#   - symlink: `git status --porcelain` tracks only a symlink's target-STRING blob,
#     not the target's content, so a symlinked component (e.g. `lib/` → an external
#     dir) makes a leaf-only -L test pass while the later read/source follows it to
#     unverified, mutated content (Cursor/Cubic/Codex + litmus, PR #280).
#   - gitlink: a committed submodule (mode 160000) is a directory, not a symlink, so
#     the -L test never fires; and `git status --porcelain -- <path-inside>` does not
#     descend into a submodule (its dirtiness surfaces only as `M <submodule>`,
#     scoped to the gitlink path), so a committed-clean check is blind to divergent
#     bytes read through it (Codex P2, issue #281). busdriver has no submodules, so
#     any gitlink on this path is anomalous — reject fail-closed.
# $1 = worktree root, $2 = path relative to it, $3 = noun for the error message.
exclusion_reject_untrusted_components() {
    local _root="$1" _rel="$2" _what="$3" _prefix="" _seg _segs _mode
    IFS=/ read -r -a _segs <<< "$_rel"
    for _seg in "${_segs[@]}"; do
        [[ -z "$_seg" || "$_seg" == "." ]] && continue
        _prefix="${_prefix:+$_prefix/}$_seg"
        if [[ -L "$_root/$_prefix" ]]; then
            _excl_fail "judgment" "excluded-only marker but in-worktree path component '$_prefix' of the $_what is a symlink; a symlinked component cannot be trusted since git status verifies only the symlink blob, not its target's content"
            return 1
        fi
        # Match the EXACT index entry for this prefix ($2==p after a tab split), NOT
        # merely the first ls-files row: for a normal directory prefix, ls-files lists
        # its DESCENDANTS, and a gitlink descendant sorted first (e.g. `.claude/sub`
        # before `.claude/review-exclude`) would otherwise set _mode=160000 and falsely
        # reject a valid excluded-only commit (Codex/cubic, PR #282). A gitlink AT the
        # prefix is the sole index entry whose path == prefix. No early awk `exit` → no
        # SIGPIPE under set -e/pipefail (the path is unique, so awk matches at most one
        # line while reading to EOF). Fail CLOSED on a genuine probe error — a git/awk
        # failure must not leave _mode empty and silently skip the gitlink check
        # (CodeRabbit, PR #282); an empty _mode from a SUCCESSFUL run (prefix has no
        # exact index entry — a normal dir or untracked component) is legitimately not
        # a gitlink.
        if ! _mode=$(git -C "$_root" ls-files --stage -- "$_prefix" 2>/dev/null \
                | awk -F'\t' -v p="$_prefix" '$2==p{split($1,h," "); print h[1]}'); then
            _excl_fail "judgment" "excluded-only marker but could not verify the index mode of in-worktree path component '$_prefix' of the $_what (git ls-files failed); rejecting fail-closed"
            return 1
        fi
        if [[ "$_mode" == "160000" ]]; then
            _excl_fail "judgment" "excluded-only marker but in-worktree path component '$_prefix' of the $_what is a gitlink/submodule (mode 160000); a submodule cannot be trusted since git status of a path inside it does not descend to verify the committed content"
            return 1
        fi
    done
    return 0
}

# Verify the exclusion POLICY ($STATE_DIR/review-exclude) matches HEAD exactly.
#
# The policy is the other half of what decides "the reviewer never sees this". Checking
# it only when the WHOLE diff turned out to be excluded is checking too late and too
# narrowly: a modified review-exclude that hides ONE staged file leaves the rest
# visible, so the excluded-only branch is never entered, the review passes on the
# remainder, and the marker — bound to the FULL snapshot — authorizes the hidden file
# too. Verify before the policy is ever read, exactly like the logic file.
#
# `git status --porcelain -uall --ignored` reports every divergence in one shot: staged
# add/modify/delete (including `git rm --cached`, which `git diff HEAD` misses because
# the worktree copy still matches HEAD), unstaged edits, and untracked (`??`). --ignored
# is required, not belt-and-braces: without it a review-exclude hidden by a committed
# .gitignore rule produces NO porcelain output while the parser reads it regardless.
# $1 = worktree root, $2 = state dir name (relative).
verify_exclusion_policy() {
    local _worktree="$1" _state_dir="$2" _base="${3:-HEAD}" _policy_rel _policy_status _policy_pinned
    # shellcheck disable=SC2034
    EXCL_LOGIC_ERROR=""
    # shellcheck disable=SC2034
    EXCL_LOGIC_ERROR_KIND=""
    # shellcheck disable=SC2034
    EXCL_POLICY_SOURCE=""
    # shellcheck disable=SC2034
    EXCL_POLICY_PINNED_TMP=""
    case "$_state_dir" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) _state_dir=".claude" ;; esac
    _policy_rel="$_state_dir/review-exclude"
    # No policy file at all is the normal case: only the hardcoded defaults apply. Pin
    # an EMPTY file rather than returning with EXCL_POLICY_SOURCE unset — an unset
    # source sends the caller's parser back to the live path, so a policy created (or a
    # dangling symlink retargeted) between this check and the parse would supply
    # patterns nothing verified. "Absent" has to be pinned as deliberately as "present",
    # or the absent case is the hole in the check-then-use protection.
    # "Absent" must mean absent in HEAD *and* in the worktree. Testing only the worktree
    # would accept a policy that HEAD carries but the worktree deleted as a clean absence,
    # short-circuiting past the committed-clean probe below and quietly contradicting this
    # function's contract that staged or unstaged deletions are refused.
    if [[ ! -e "$_worktree/$_policy_rel" ]] && ! git -C "$_worktree" cat-file -e "$_base:$_policy_rel" 2>/dev/null; then
        if ! _policy_pinned=$(mktemp -t busdriver-excl-policy-XXXXXX); then
            _excl_fail "env" "could not create a temp file to pin the absent exclusion policy; fail-closed"
            return 1
        fi
        : > "$_policy_pinned"
        # shellcheck disable=SC2034
        EXCL_POLICY_SOURCE="$_policy_pinned"
        # shellcheck disable=SC2034
        EXCL_POLICY_PINNED_TMP="$_policy_pinned"
        return 0
    fi
    exclusion_reject_untrusted_components "$_worktree" "$_policy_rel" "exclusion policy" || return 1
    if _policy_status=$(git -C "$_worktree" status --porcelain --untracked-files=all --ignored -- "$_policy_rel" 2>/dev/null); then
        if [[ -n "$_policy_status" ]]; then
            _excl_fail "judgment" "the exclusion policy ($_policy_rel) has uncommitted, untracked, or ignored divergence from HEAD; the policy deciding what a reviewer never sees must itself be committed and reviewed"
            return 1
        fi
    else
        _excl_fail "judgment" "could not verify the exclusion policy ($_policy_rel) is committed-clean (git status failed); fail-closed"
        return 1
    fi
    # Hand back COMMITTED bytes for the same check-then-use reason as the logic file:
    # verifying the worktree path and then letting the parser re-read that path leaves a
    # window where a swap widens the exclusions. Materialise HEAD's blob and have the
    # caller point the parser at it.
    if ! _policy_pinned=$(mktemp -t busdriver-excl-policy-XXXXXX); then
        _excl_fail "env" "could not create a temp file to pin the committed exclusion policy; fail-closed"
        return 1
    fi
    if ! git -C "$_worktree" show "$_base:$_policy_rel" > "$_policy_pinned" 2>/dev/null; then
        rm -f "$_policy_pinned"
        _excl_fail "judgment" "could not read the COMMITTED exclusion policy ($_policy_rel) from HEAD; refusing to use the worktree copy instead"
        return 1
    fi
    # shellcheck disable=SC2034
    EXCL_POLICY_SOURCE="$_policy_pinned"
    # shellcheck disable=SC2034
    EXCL_POLICY_PINNED_TMP="$_policy_pinned"
    return 0
}

# Verify the exclusion LOGIC file is safe to source.
#
# Sourcing it runs its code AND its hardcoded defaults + review-exclude parse decide
# what counts as excluded. It is normally trusted plugin code OUTSIDE the reviewed
# worktree (the plugin cache), but when the plugin root IS the worktree (busdriver
# self-review) a tampered copy could redefine REVIEW_EXCLUDE_ARGS — or run arbitrary
# code — to over-exclude real source.
#
# Membership is decided LEXICALLY against the worktree rather than by index or
# physical realpath. Both prior approaches were defeatable: `git ls-files
# --error-unmatch` by `git rm --cached` (untracks but keeps the tamperable copy), and
# `pwd -P` by swapping an in-worktree path component for a symlink to an external
# dir. A lexical prefix check + `git status` on the tracked path sidesteps both: git
# reports divergence on the TRACKED path regardless of physical resolution, so a
# swapped-to-symlink `lib/` shows its tracked files as deleted and an `rm --cached`
# shows the copy as untracked — either way non-empty ⇒ refuse.
verify_exclusion_logic() {
    local _worktree="$1" _litmus_scripts="$2" _base="${3:-HEAD}"
    local _wt _excl_logic_file _excl_logic_rel _excl_logic_status _real_wt _real_excl_dir
    local _excl_target _excl_hops _excl_link _excl_nlink _excl_pinned _excl_wt_prefix

    # shellcheck disable=SC2034
    EXCL_LOGIC_SOURCE=""
    # shellcheck disable=SC2034
    EXCL_LOGIC_ERROR=""
    # shellcheck disable=SC2034
    EXCL_LOGIC_ERROR_KIND=""
    # shellcheck disable=SC2034
    EXCL_LOGIC_PINNED_TMP=""

    _excl_logic_file="$_litmus_scripts/lib/exclude-generated.sh"

    # Strip trailing slashes from the worktree (an operator-supplied input): with a
    # trailing slash the "$_wt"/* pattern becomes `/repo//*` and fails to match a
    # normal `/repo/skills/...` path, silently SKIPPING the guard. Keep "/" itself
    # intact (degenerate root case).
    _wt="$_worktree"
    while [[ "$_wt" == */ && "$_wt" != "/" ]]; do _wt="${_wt%/}"; done

    # Normalize to absolute: a RELATIVE plugin root (e.g. CLAUDE_PLUGIN_ROOT=.)
    # resolves against cwd, which callers set to the worktree. Without this, a
    # relative path would fail the "$_wt"/* prefix test and skip the guard even
    # though the file is in-worktree.
    case "$_excl_logic_file" in
        /*) : ;;
        *)  _excl_logic_file="$_wt/$_excl_logic_file" ;;
    esac

    # Apply the IDENTICAL collapse to $_wt itself, not just the logic path:
    # collapsing normalizes away incidental double-slashes too, and comparing an
    # un-collapsed worktree against a collapsed logic path would desync the prefix
    # match even when both genuinely point at the same in-worktree file.
    _wt=$(exclusion_lexical_collapse "$_wt")
    _excl_logic_file=$(exclusion_lexical_collapse "$_excl_logic_file")
    # Membership prefix. When the worktree IS filesystem root, "$_wt"/* expands to //*,
    # which does not match a normal /skills/... path — every in-worktree file would be
    # misclassified as trusted-external, skipping the committed-clean check and the HEAD
    # pinning entirely. Build the prefix once, correctly, and use it everywhere below.
    if [[ "$_wt" == "/" ]]; then
        _excl_wt_prefix="/"
    else
        _excl_wt_prefix="$_wt/"
    fi

    # Check-vs-use consistency (litmus, PR #280): the caller MUST source the exact
    # path this guard validated. Handing back the ORIGINAL, un-collapsed path while
    # validating the collapsed one lets the two diverge when the path contains ".."
    # across a symlink component (verify one file, execute another).
    EXCL_LOGIC_SOURCE="$_excl_logic_file"

    # Symlinked-plugin-root defense (Codex, PR #280): the LEXICAL prefix check below
    # only classifies the file as in-worktree when it is lexically under $_wt. If the
    # plugin root is itself a symlink whose TARGET lives inside the worktree (a
    # self-review layout where the plugin root is symlinked to the checkout rather
    # than set to it directly), the lexical path runs through the symlink and never
    # matches "$_wt"/*, so classification falls through to "trusted-external" and
    # skips the committed-clean guard entirely — while `.`-sourcing it later follows
    # the symlink and loads the file's real (physical) bytes, which DO live in the
    # mutable worktree. Resolve both to PHYSICAL paths ONCE, using only trusted
    # operator/environment-set roots (not attacker-controlled path components),
    # purely to catch that classification mismatch. This does not replace or weaken
    # the lexical + component defense used for the already-in-worktree case below.
    if [[ "$_excl_logic_file" != "$_excl_wt_prefix"* ]]; then
        if ! _real_wt=$(cd "$_wt" 2>/dev/null && pwd -P); then
            _excl_fail "env" "could not resolve real path of worktree ($_wt) to check for a symlinked plugin root"
            return 1
        fi
        # Resolve the FILE's own symlink chain, not just its directory. An external
        # directory holding a symlink that points INTO the worktree passes a
        # dirname-only check — _real_excl_dir stays outside — while the later
        # `.`-source follows the link and loads mutable worktree bytes as "trusted
        # external" logic. Follow the chain with a hop cap so a symlink loop cannot
        # spin here. (A legitimate plugin install may symlink this file, so refusing
        # symlinks outright is not an option — resolve first, then classify.)
        _excl_target="$_excl_logic_file"
        _excl_hops=0
        while [[ -L "$_excl_target" ]] && [[ "$_excl_hops" -lt 40 ]]; do
            if ! _excl_link=$(readlink "$_excl_target" 2>/dev/null); then
                _excl_fail "judgment" "exclusion logic path ($_excl_logic_file) contains a symlink that could not be resolved (readlink failed at '$_excl_target'); an unresolved chain cannot be classified as trusted-external, so rejecting fail-closed"
                return 1
            fi
            case "$_excl_link" in
                /*) _excl_target="$_excl_link" ;;
                *)  _excl_target="$(dirname "$_excl_target")/$_excl_link" ;;
            esac
            _excl_hops=$((_excl_hops + 1))
        done
        # An UNTERMINATED chain must not fall through to "classify the last path we
        # happened to reach". Both exits from the loop that leave a symlink behind —
        # hop-limit exhaustion and a readlink error above — are "could not determine
        # where this actually points", and a chain longer than the cap can stay
        # lexically external while resolving into the mutable worktree. Refuse.
        if [[ -L "$_excl_target" ]]; then
            _excl_fail "judgment" "exclusion logic path ($_excl_logic_file) is a symlink chain longer than 40 hops; refusing to classify an unresolved chain as trusted-external"
            return 1
        fi
        # A HARDLINK defeats every path-based check above: it is not a symlink, so the
        # chain walk sees nothing, and its external pathname genuinely resolves outside
        # the worktree — yet editing the worktree's link mutates these very bytes,
        # which are then sourced as "trusted external" logic. There is no cheap way to
        # ask "is this linked to anything under the worktree" (a `find -samefile` over
        # the tree is far too slow for a gate), so use the property that makes the
        # attack possible at all: a link count above 1. A plugin-cache install is a
        # plain copy with exactly one link.
        #
        # Deliberately fail-closed on the ambiguous case rather than proving intent.
        # The cost is bounded and asymmetric: run-review-loop.sh degrades to reviewing
        # with NO exclusions (nothing is hidden, no lockout), and the dispatcher refuses
        # one excluded-only auto-pass. If a future installer hardlinks plugin files this
        # will surface as that refusal, which is a visible, diagnosable stall — the
        # trade this repo already makes everywhere else.
        # Probe GNU (`-c %h`) FIRST, then BSD (`-f %l`), and refuse if neither answers.
        # Order and fail-closed-ness both matter. `-f` means --file-system on GNU and
        # takes FILE operands, so `stat -f %l "$target"` there treats `%l` as another
        # filename: if a file named `%l` happens to exist it SUCCEEDS with non-numeric
        # output, the fallback never runs, and a `-n`-guarded check would silently skip
        # the rejection — a fail-OPEN in the guard itself. BSD rejects `-c` outright
        # (`illegal option -- c`, measured), so trying GNU first is safe on both.
        # An undeterminable link count is "cannot prove this is not hardlinked into the
        # worktree", which is a refusal, not a pass.
        _excl_nlink=$(stat -c %h "$_excl_target" 2>/dev/null || true)
        if ! [[ "$_excl_nlink" =~ ^[0-9]+$ ]]; then
            _excl_nlink=$(stat -f %l "$_excl_target" 2>/dev/null || true)
        fi
        if ! [[ "$_excl_nlink" =~ ^[0-9]+$ ]]; then
            _excl_fail "judgment" "could not determine the hard-link count of the exclusion logic ($_excl_logic_file); without it a hardlink into the reviewed worktree cannot be ruled out — refusing fail-closed"
            return 1
        fi
        if [[ "$_excl_nlink" -gt 1 ]]; then
            _excl_fail "judgment" "exclusion logic ($_excl_logic_file) resolves outside the worktree but has $_excl_nlink hard links; a hardlink into the reviewed worktree would make its bytes editable there while this path still looks trusted-external, and that cannot be ruled out cheaply — refusing fail-closed"
            return 1
        fi
        # Fail CLOSED if the directory cannot be resolved. `|| _real_excl_dir=""`
        # turned a probe error into an empty string, and the emptiness test below then
        # read that as "not inside the worktree" — so a filesystem error or a race
        # silently WAIVED the very check that detects a path resolving into the mutable
        # worktree. "Could not determine" is not "determined to be safe".
        if ! _real_excl_dir=$(cd "$(dirname "$_excl_target")" 2>/dev/null && pwd -P); then
            _excl_fail "env" "could not resolve the real path of the exclusion logic directory ($(dirname "$_excl_target")); cannot classify it as trusted-external, refusing fail-closed"
            return 1
        fi
        if [[ -z "$_real_excl_dir" ]]; then
            _excl_fail "env" "empty real path for the exclusion logic directory; cannot classify it as trusted-external, refusing fail-closed"
            return 1
        fi
        if [[ "$_real_excl_dir" == "$_real_wt" ]] || [[ "$_real_excl_dir" == "$_real_wt"/* ]]; then
            _excl_fail "judgment" "exclusion logic path ($_excl_logic_file) is lexically outside the worktree but physically resolves inside it ($_real_excl_dir) — the plugin root is likely a symlink into the worktree, so it cannot safely be treated as trusted-external. Point BUSDRIVER_PLUGIN_ROOT/CLAUDE_PLUGIN_ROOT at a location outside the worktree, or set it to the worktree path directly so the in-worktree guard applies."
            return 1
        fi
    fi

    case "$_excl_logic_file" in
        "$_excl_wt_prefix"*)
            _excl_logic_rel="${_excl_logic_file#"$_excl_wt_prefix"}"
            exclusion_reject_untrusted_components "$_wt" "$_excl_logic_rel" "exclusion logic" || return 1
            # Distinguish "git status succeeded, output empty (clean)" from "git
            # status FAILED": a bare `2>/dev/null || true` would collapse an error
            # into empty and fail OPEN. Only an empty status from a SUCCESSFUL run
            # means clean. --ignored is required, not belt-and-braces: without it a
            # logic file hidden by a repo-committed .gitignore rule produces NO
            # porcelain output while it is still sourced.
            if _excl_logic_status=$(git -C "$_wt" status --porcelain --untracked-files=all --ignored -- "$_excl_logic_rel" 2>/dev/null); then
                if [[ -n "$_excl_logic_status" ]]; then
                    _excl_fail "judgment" "excluded-only marker but the exclusion logic ($_excl_logic_rel) has uncommitted, untracked, or deleted changes; the logic governing an excluded-only auto-pass must be committed and reviewed"
                    return 1
                fi
            else
                _excl_fail "judgment" "excluded-only marker but could not verify the exclusion logic ($_excl_logic_rel) is committed-clean (git status failed); fail-closed"
                return 1
            fi
            # Hand back COMMITTED bytes, not the worktree path. Verifying the file and
            # then sourcing the same path is a check-then-use window: a swap between the
            # two loads logic that was never checked, and re-checking afterwards cannot
            # close it (an A -> malicious-B -> A swap passes both checks). Materialising
            # HEAD's blob removes the window by construction — what gets sourced is what
            # `git status` just proved the worktree matches, and a mid-flight swap can no
            # longer change it. The extraction is verified too: a truncated or failed
            # `git show` must refuse, never source a partial file.
            if ! _excl_pinned=$(mktemp -t busdriver-excl-XXXXXX); then
                _excl_fail "env" "could not create a temp file to pin the committed exclusion logic; fail-closed"
                return 1
            fi
            if ! git -C "$_wt" show "$_base:$_excl_logic_rel" > "$_excl_pinned" 2>/dev/null; then
                rm -f "$_excl_pinned"
                _excl_fail "judgment" "could not read the COMMITTED exclusion logic ($_excl_logic_rel) from HEAD; refusing to source the worktree copy instead"
                return 1
            fi
            if [[ ! -s "$_excl_pinned" ]]; then
                rm -f "$_excl_pinned"
                _excl_fail "judgment" "the committed exclusion logic ($_excl_logic_rel) extracted empty; fail-closed"
                return 1
            fi
            # shellcheck disable=SC2034
            EXCL_LOGIC_SOURCE="$_excl_pinned"
            # shellcheck disable=SC2034
            EXCL_LOGIC_PINNED_TMP="$_excl_pinned"
            ;;
    esac
    return 0
}
