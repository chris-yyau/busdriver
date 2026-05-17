#!/usr/bin/env bash
# scripts/lib/bail-envelope.sh — dispatcher bail-envelope emit + parse.
#
# Categories (post-inversion; `tooling` removed):
#   - judgment  (worker triage, litmus stall/max-iter/infra, marker validation, commitlint)
#   - env       (auth/network during push, missing commitlint binary)
#   - budget    (loop exhaustion — dispatcher-emitted)
#   - policy    (approver-gap — dispatcher-emitted)
#
# Emit usage (child shell exits 1 after emit):
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/bail-envelope.sh"
#   emit_bail "judgment" "litmus stall"
#
# Parent-parse usage (SAFE PATTERN — addresses iter-1 MED #1):
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/bail-envelope.sh"
#   child_output=$(bash "$CHILD_SCRIPT" 2>&1 || true)
#   bail_json=$(printf '%s\n' "$child_output" | parse_bail_envelope)
#   # bail_json is "" if no envelope, otherwise the JSON object
#
# DO NOT chain `child | source ...; parse_bail_envelope` — `source` in a
# pipeline runs in a subshell and the function isn't defined in the parent.

emit_bail() {
    local category="${1:-}"
    local reason="${2:-}"
    case "$category" in
        judgment|env|budget|policy) ;;
        *) printf 'invalid bail_category: %s\n' "$category" >&2; exit 2 ;;
    esac
    jq -nc --arg c "$category" --arg r "$reason" '{bail_category: $c, bail_reason: $r}'
    exit 1
}

parse_bail_envelope() {
    # Match any line containing "bail_category" (not anchored to line-start
    # so key-insertion order from different jq invocations doesn't matter).
    # Then validate the matched line is well-formed JSON with both required
    # fields before returning it; malformed or partial envelopes are dropped.
    # shellcheck disable=SC2312  # empty output is success-equivalent (no envelope found)
    grep -E '"bail_category"' | tail -n 1 | \
        jq -ce 'select(type == "object" and has("bail_category") and has("bail_reason"))' 2>/dev/null || true
}
