#!/bin/bash
# Shared litmus marker validation against the current staged diff (git diff --cached).
# Used by native Git merge hooks (#622). Marker shapes match pre-commit-gate.sh Gate 2.
#
# Hash form: bare `git diff --cached` plus `--no-ext-diff --no-textconv`, with
# GIT_EXTERNAL_DIFF / textconv-related env scrubbed. When no external driver is
# configured this matches litmus writers; when a driver is injected it fail-closes.
#
# Callers MUST pin PATH to trusted directories (e.g. /usr/bin:/bin) before sourcing.
#
# Usage (after sourcing resolve-repo-dir.sh):
#   gate_validate_staged_litmus_marker REPO_DIR [STATE_DIR]
# Returns 0 when the staged diff is authorized; 1 on block (reason in GATE_VALIDATE_REASON).
# On success, writes a one-use merge-litmus-pending.local claim for post-merge/post-commit.

# shellcheck disable=SC2034  # GATE_VALIDATE_REASON set for callers
GATE_VALIDATE_REASON=""

_gate_merge_pending_lib() {
    local _src _dir _pwd
    _src="${BASH_SOURCE[0]}"
    while [[ -L "$_src" ]]; do
        _src=$(readlink "$_src") || return 1
    done
    _dir=$(dirname "$_src")
    _pwd=$(cd "$_dir" && pwd) || return 1
    printf '%s\n' "$_pwd"
}

_gate_merge_python() {
    local repo_dir="$1" lib="$2" mod_fn="$3"
    shift 3
    (cd "$repo_dir" && python3 -I -S -c "
import sys
sys.path.insert(0, sys.argv.pop(1))
from merge_pending import ${mod_fn}
raise SystemExit(0 if ${mod_fn}('.', *sys.argv[1:]) else 1)
" "$lib" "$@")
}

gate_merge_pending_invoke() {
    local repo_dir="$1" state_dir="$2" subcmd="$3" gate_name="${4:-}" claim_head="${5:-}" marker_content="${6:-}"
    local lib
    lib=$(_gate_merge_pending_lib) || return 1
    case "$subcmd" in
        write)
            _gate_merge_python "$repo_dir" "$lib" write_claim "$state_dir" "$claim_head" "$marker_content"
            ;;
        clear)
            _gate_merge_python "$repo_dir" "$lib" clear_claim_repo "$state_dir"
            ;;
        consume)
            _gate_merge_python "$repo_dir" "$lib" consume_if_pending "$state_dir" "$gate_name"
            ;;
        skip)
            _gate_merge_python "$repo_dir" "$lib" authorize_operator_skip "$state_dir" "$gate_name" "$claim_head" "$marker_content"
            ;;
        read_marker)
            (cd "$repo_dir" && python3 -I -S -c "
import sys
sys.path.insert(0, sys.argv.pop(1))
from merge_pending import read_marker_content
content = read_marker_content('.', sys.argv[1])
if content is None:
    raise SystemExit(1)
sys.stdout.write(content)
" "$lib" "$state_dir")
            ;;
        unlink_marker)
            _gate_merge_python "$repo_dir" "$lib" unlink_marker "$state_dir"
            ;;
        *)
            return 1
            ;;
    esac
}

gate_merge_pending_write() {
    local repo_dir="$1" state_dir="$2" marker_content="$3"
    local claim_head
    claim_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo unknown)
    gate_merge_pending_invoke "$repo_dir" "$state_dir" write "" "$claim_head" "$marker_content"
}

gate_merge_pending_clear() {
    gate_merge_pending_invoke "$1" "$2" clear
}

gate_merge_consume_if_pending() {
    gate_merge_pending_invoke "$1" "$2" consume "$3"
}

gate_marker_read() {
    gate_merge_pending_invoke "$1" "$2" read_marker
}

gate_marker_unlink() {
    gate_merge_pending_invoke "$1" "$2" unlink_marker
}

gate_validate_staged_litmus_marker() {
    local repo_dir="$1"
    local state_dir="${2:-${BUSDRIVER_STATE_DIR:-.claude}}"
    case "$state_dir" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) state_dir=".claude" ;; esac

    # Scrub inherited Git knobs that can replace porcelain diff output.
    unset GIT_EXTERNAL_DIFF GIT_TEXTCONV DIFF || true

    if [[ -f "$repo_dir/$state_dir/skip-litmus.local" ]] \
       && ! gate_skip_file_repo_controlled "$repo_dir" "$state_dir/skip-litmus.local"; then
        local claim_head
        claim_head=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo unknown)
        if ! gate_merge_pending_invoke "$repo_dir" "$state_dir" skip "pre-merge-commit" "$claim_head" "SKIPPED-OPERATOR"; then
            GATE_VALIDATE_REASON="BLOCKED: skip-litmus.local is too new, has invalid provenance, or could not be consumed (must be ≥30s old to prevent self-bypass).

If the USER just created this file: wait at least 30 seconds, then retry.
If YOU created this file: STOP. Do NOT create skip files yourself. Run /litmus instead."
            return 1
        fi
        return 0
    fi

    local marker_content
    marker_content=$(gate_marker_read "$repo_dir" "$state_dir" 2>/dev/null || echo "")
    if [[ -n "$marker_content" ]] \
       && gate_skip_file_repo_controlled "$repo_dir" "$state_dir/litmus-passed.local"; then
        gate_marker_unlink "$repo_dir" "$state_dir"
        GATE_VALIDATE_REASON="Review marker cannot be repository-controlled (committed or index-staged). Run /litmus."
        return 1
    fi
    if [[ -z "$marker_content" ]]; then
        GATE_VALIDATE_REASON="Code review required before merging.

Run /litmus to review the merge result. The review must pass before git merge can create a merge commit.

IMPORTANT: Do NOT create the skip file yourself. That is a user-only escape hatch. You MUST run litmus instead.
If the user wants to skip: touch $repo_dir/$state_dir/skip-litmus.local
After the user creates the skip file, WAIT 30 SECONDS before retrying (the gate rejects files newer than 30s to prevent self-bypass)."
        return 1
    fi

    if echo "$marker_content" | grep -q "^DEGRADED"; then
        gate_marker_unlink "$repo_dir" "$state_dir"
        GATE_VALIDATE_REASON="Code review ran in DEGRADED mode (no review CLI installed). No actual code review was performed. Install a review CLI or create $state_dir/skip-litmus.local to bypass."
        return 1
    elif [[ "$marker_content" =~ ^SKIPPED-NONE-[0-9]+$ ]]; then
        local skipped_epoch skipped_age now_epoch
        skipped_epoch=${marker_content#SKIPPED-NONE-}
        if [[ ! "$skipped_epoch" =~ ^[0-9]{1,10}$ ]]; then
            gate_marker_unlink "$repo_dir" "$state_dir"
            GATE_VALIDATE_REASON="SKIPPED-NONE marker has an invalid epoch. Run /litmus."
            return 1
        fi
        now_epoch=$(date +%s)
        skipped_epoch=$((10#$skipped_epoch))
        if [[ "$skipped_epoch" -gt "$now_epoch" ]]; then
            gate_marker_unlink "$repo_dir" "$state_dir"
            GATE_VALIDATE_REASON="SKIPPED-NONE marker has a future epoch. Run /litmus."
            return 1
        fi
        skipped_age=$(( now_epoch - skipped_epoch ))
        if [[ "$skipped_age" -gt 3600 ]]; then
            gate_marker_unlink "$repo_dir" "$state_dir"
            GATE_VALIDATE_REASON="SKIPPED-NONE marker is stale (over 1h old). Run /litmus."
            return 1
        fi
        if ! gate_merge_pending_write "$repo_dir" "$state_dir" "$marker_content"; then
            GATE_VALIDATE_REASON="Could not persist the one-use merge claim."
            return 1
        fi
        return 0
    fi

    if [[ "$marker_content" =~ ^PASS-MERGE-[0-9]+$ ]]; then
        local merge_epoch merge_age now_epoch
        merge_epoch=${marker_content#PASS-MERGE-}
        if [[ ! "$merge_epoch" =~ ^[0-9]{1,10}$ ]]; then
            gate_marker_unlink "$repo_dir" "$state_dir"
            GATE_VALIDATE_REASON="PASS-MERGE marker has an invalid epoch. Run /litmus."
            return 1
        fi
        now_epoch=$(date +%s)
        merge_epoch=$((10#$merge_epoch))
        if [[ "$merge_epoch" -gt "$now_epoch" ]]; then
            gate_marker_unlink "$repo_dir" "$state_dir"
            GATE_VALIDATE_REASON="PASS-MERGE marker has a future epoch. Run /litmus."
            return 1
        fi
        merge_age=$(( now_epoch - merge_epoch ))
        if [[ "$merge_age" -gt 3600 ]]; then
            gate_marker_unlink "$repo_dir" "$state_dir"
            GATE_VALIDATE_REASON="PASS-MERGE marker is stale (over 1h old). Run /litmus."
            return 1
        fi
        if git -C "$repo_dir" -c diff.external= -c diff.ignoreSubmodules=none diff --cached --no-ext-diff --no-textconv --quiet 2>/dev/null; then
            if ! gate_merge_pending_write "$repo_dir" "$state_dir" "$marker_content"; then
                GATE_VALIDATE_REASON="Could not persist the one-use merge claim."
                return 1
            fi
            return 0
        fi
        gate_marker_unlink "$repo_dir" "$state_dir"
        GATE_VALIDATE_REASON="PASS-MERGE review marker present but the staged diff is not empty. That marker is only minted for a merge whose resolution changed nothing; a merge with real resolutions must be reviewed. Run /litmus."
        return 1
    fi

    local staged_hash="" hash_cmd=() hash_rc=0 diff_out="" hash_line=""
    if command -v sha256sum >/dev/null 2>&1; then
        hash_cmd=(sha256sum)
    elif command -v shasum >/dev/null 2>&1; then
        hash_cmd=(shasum -a 256)
    fi
    if [[ ${#hash_cmd[@]} -eq 0 ]]; then
        GATE_VALIDATE_REASON="Could not compute the staged-diff hash (external diff driver or hashing tool failed, or no hash utility is installed). Blocking rather than assuming a pass; the review marker is preserved so a retry can validate it once the environment is repaired. Run /litmus, or create $state_dir/skip-litmus.local to bypass."
        return 1
    fi
    # --no-ext-diff --no-textconv: ignore inherited drivers; -c diff.external= clears config.
    diff_out=$(git -C "$repo_dir" -c diff.external= -c diff.ignoreSubmodules=none diff --cached --no-ext-diff --no-textconv 2>/dev/null) || hash_rc=$?
    if [[ "$hash_rc" -ne 0 ]]; then
        GATE_VALIDATE_REASON="Could not compute the staged-diff hash (external diff driver or hashing tool failed, or no hash utility is installed). Blocking rather than assuming a pass; the review marker is preserved so a retry can validate it once the environment is repaired. Run /litmus, or create $state_dir/skip-litmus.local to bypass."
        return 1
    fi
    hash_line=$({ printf '%s\n' "$diff_out" | "${hash_cmd[@]}"; }) || hash_rc=$?
    if [[ "$hash_rc" -ne 0 ]]; then
        GATE_VALIDATE_REASON="Could not compute the staged-diff hash (external diff driver or hashing tool failed, or no hash utility is installed). Blocking rather than assuming a pass; the review marker is preserved so a retry can validate it once the environment is repaired. Run /litmus, or create $state_dir/skip-litmus.local to bypass."
        return 1
    fi
    staged_hash=$(printf '%s' "$hash_line" | cut -d' ' -f1)
    if [[ -z "$staged_hash" ]]; then
        GATE_VALIDATE_REASON="Could not compute the staged-diff hash (external diff driver or hashing tool failed, or no hash utility is installed). Blocking rather than assuming a pass; the review marker is preserved so a retry can validate it once the environment is repaired. Run /litmus, or create $state_dir/skip-litmus.local to bypass."
        return 1
    fi

    if [[ "$marker_content" =~ ^PASS-EXCLUDED-[a-f0-9]{64}-[0-9]{1,15}$ ]]; then
        local excluded_hash excluded_epoch excluded_age
        excluded_hash=$(printf '%s' "$marker_content" | sed -E 's/^PASS-EXCLUDED-([a-f0-9]{64})-[0-9]{1,15}$/\1/')
        excluded_epoch=$(printf '%s' "$marker_content" | sed -E 's/^PASS-EXCLUDED-[a-f0-9]{64}-([0-9]{1,15})$/\1/')
        excluded_epoch=$((10#$excluded_epoch))
        excluded_age=$(( $(date +%s) - excluded_epoch ))
        if [[ -n "$staged_hash" && "$excluded_hash" == "$staged_hash" \
            && "$excluded_age" -ge 0 && "$excluded_age" -le 3600 ]]; then
            if ! gate_merge_pending_write "$repo_dir" "$state_dir" "$marker_content"; then
                GATE_VALIDATE_REASON="Could not persist the one-use merge claim."
                return 1
            fi
            return 0
        fi
        gate_marker_unlink "$repo_dir" "$state_dir"
        GATE_VALIDATE_REASON="Excluded-only review marker is stale (over 1h old) or names a different diff than the one staged. Run /litmus."
        return 1
    elif echo "$marker_content" | grep -qE '^BUILTIN-[a-f0-9]{64}$'; then
        local builtin_hash=${marker_content#BUILTIN-}
        if [[ -n "$staged_hash" && "$builtin_hash" == "$staged_hash" ]]; then
            if ! gate_merge_pending_write "$repo_dir" "$state_dir" "$marker_content"; then
                GATE_VALIDATE_REASON="Could not persist the one-use merge claim."
                return 1
            fi
            return 0
        fi
        gate_marker_unlink "$repo_dir" "$state_dir"
        GATE_VALIDATE_REASON="Builtin review marker is for a different diff than the one staged. Re-run /litmus so the review covers what you are merging."
        return 1
    elif echo "$marker_content" | grep -qE '^[a-f0-9]{64}$'; then
        if [[ -n "$staged_hash" && "$marker_content" == "$staged_hash" ]]; then
            if ! gate_merge_pending_write "$repo_dir" "$state_dir" "$marker_content"; then
                GATE_VALIDATE_REASON="Could not persist the one-use merge claim."
                return 1
            fi
            return 0
        fi
        gate_marker_unlink "$repo_dir" "$state_dir"
        GATE_VALIDATE_REASON="Review marker is for a different diff than the one staged (marker ${marker_content:0:12}..., staged ${staged_hash:0:12}...). A review of one diff cannot authorize merging another. Run /litmus."
        return 1
    fi

    gate_marker_unlink "$repo_dir" "$state_dir"
    GATE_VALIDATE_REASON="Review marker content not recognized: ${marker_content:0:30}... Rejecting rather than assuming a pass. Run /litmus."
    return 1
}
