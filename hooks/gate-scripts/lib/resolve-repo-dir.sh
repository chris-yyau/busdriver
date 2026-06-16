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
    # resolves it faithfully without evaluating the substitution.
    # SC2016: the $(/backtick literals are the patterns we match, not expansions.
    # shellcheck disable=SC2016
    if printf '%s' "$t" | grep -Eq '^(\$\(|`)git rev-parse --show-(toplevel|cdup)(\)|`)$'; then
        printf 'toplevel\n'; return 0
    fi
    # Any other command substitution / unguarded param-expansion is opaque to a
    # static parser -> unresolvable (caller fails CLOSED).
    # shellcheck disable=SC2016
    case "$t" in
        *'$('*|*'`'*|*'${'*) printf 'unresolvable\n'; return 0 ;;
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
        anchor="$target"
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
