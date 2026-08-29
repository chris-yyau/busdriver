#!/usr/bin/env bash
# tests/test-litmus-delayed-marker-790.sh — the delayed builtin marker writer must
# not overwrite a marker some OTHER run published after our handoff was armed (#790).
#
# The builtin fallback mints its marker from a separate process: run-review-loop.sh
# exits 3 (arming the handoff and snapshotting the marker generation), an agent
# reviews, then the writer publishes litmus-passed.local. The review lock is released
# at exit 3 by design, so a second run can complete an ordinary review and publish its
# marker while the first run's agent is still thinking. Without ordering, the delayed
# writer clobbers the newer marker and the next commit is spuriously blocked.
#
# Usage: bash tests/test-litmus-delayed-marker-790.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."
# Every fixture below is written under a literal .claude, so an inherited
# BUSDRIVER_STATE_DIR would point the writer at a directory nothing was armed in and
# fail the suite for a reason it is not testing. Case 14 sets it per invocation.
unset BUSDRIVER_STATE_DIR
WRITER="$PWD/skills/litmus/scripts/write-review-marker.sh"
LOOP="$PWD/skills/litmus/scripts/run-review-loop.sh"

PASS=0
FAIL=0

ok()    { printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
bad()   { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }
exists() { if [[ -e "$1" ]]; then printf 'present'; else printf 'gone'; fi; }
verdict() { if [[ "$1" -ne 0 ]]; then printf 'refused'; else printf 'wrote'; fi; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/litmus-790-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# A fresh repo with something staged, so the writer has a diff to hash.
new_repo() {
    local d="$WORK/$1"
    rm -rf "$d"; mkdir -p "$d"
    git -C "$d" init -q
    printf 'staged\n' > "$d/file.txt"
    git -C "$d" add file.txt
    mkdir -p "$d/.claude"
    printf '%s' "$d"
}

PROMPT="/tmp/busdriver-review-790prompt"

# What any marker publisher does: stamp a fresh generation, then write the marker.
publish() {
    printf 'gen-%s-%s\n' "$RANDOM" "$RANDOM" > "$1/.claude/litmus-marker-gen.local"
    printf '%s\n' "$2" > "$1/.claude/litmus-passed.local"
}

# What run-review-loop.sh does at exit 3: arm the handoff and snapshot the generation.
# $2 overrides the prompt path, standing in for a LATER run re-arming the handoff.
arm_handoff() {
    printf '%s\n' "${2:-$PROMPT}" > "$1/.claude/builtin-review-prompt-path.local"
    if [[ -f "$1/.claude/litmus-marker-gen.local" ]]; then
        cp "$1/.claude/litmus-marker-gen.local" "$1/.claude/builtin-review-marker-baseline.local"
    else
        printf 'ABSENT\n' > "$1/.claude/builtin-review-marker-baseline.local"
    fi
}

# Run the writer inside repo $1, claiming prompt path $2 (default: the armed one).
# Sets RC and OUT.
run_writer() {
    RC=0
    OUT=$( (cd "$1" && bash "$WRITER" "${2-$PROMPT}") 2>&1 ) || RC=$?
}

# Same, in --discard mode: retire the arming without writing a marker.
run_discard() {
    RC=0
    OUT=$( (cd "$1" && bash "$WRITER" --discard "${2-$PROMPT}") 2>&1 ) || RC=$?
}

echo "── #790 delayed builtin marker writer ───────────────────────"

# 1. A marker published by another run AFTER the handoff was armed is NOT overwritten.
R=$(new_repo newer)
arm_handoff "$R"
publish "$R" "deadbeefnewerreview"
run_writer "$R"
check "newer marker refuses" "$(verdict "$RC")" "refused"
GOT=$(cat "$R/.claude/litmus-passed.local")
check "newer marker preserved verbatim" "$GOT" "deadbeefnewerreview"
check "handoff consumed on refusal" "$(exists "$R/.claude/builtin-review-prompt-path.local")" "gone"
check "baseline consumed on refusal" "$(exists "$R/.claude/builtin-review-marker-baseline.local")" "gone"
if printf '%s' "$OUT" | grep -qi "newer review"; then
    ok "refusal explains why"
else
    bad "refusal message does not mention a newer review: $OUT"
fi

# 2. Byte-identical republication (ABA) is still a publication: the generation moved
#    even though the content did not, so the newer marker must still stand.
R=$(new_repo aba)
publish "$R" "samecontentbothtimes"
arm_handoff "$R"
publish "$R" "samecontentbothtimes"
run_writer "$R"
check "ABA republication refuses" "$(verdict "$RC")" "refused"
GOT=$(cat "$R/.claude/litmus-passed.local")
check "ABA marker preserved" "$GOT" "samecontentbothtimes"

# 3. Nobody published since exit 3 — overwrite this run's own marker, as before. This
#    is the ordinary path and must stay unrefused: refusing here is the reverted
#    freshness check the issue warns against re-adding. What the marker binds to is
#    NOT asserted either way — the writer hashes the index at write time, which is
#    pre-existing behaviour owned by #576, untouched here.
R=$(new_repo unchanged)
publish "$R" "markerfromanearlierrun"
arm_handoff "$R"
GEN_BEFORE=$(cat "$R/.claude/litmus-marker-gen.local")
run_writer "$R"
check "unchanged generation: writer succeeds" "$(verdict "$RC")" "wrote"
if grep -q '^BUILTIN-[0-9a-f]\{64\}$' "$R/.claude/litmus-passed.local"; then
    ok "own marker overwritten with BUILTIN-<hash>"
else
    GOT=$(cat "$R/.claude/litmus-passed.local")
    bad "marker not replaced: $GOT"
fi
check "handoff consumed on write" "$(exists "$R/.claude/builtin-review-prompt-path.local")" "gone"

# 4. Our own write stamps a fresh generation, so the NEXT delayed writer can see it.
GOT=$(cat "$R/.claude/litmus-marker-gen.local")
if [[ -n "$GOT" && "$GOT" != "$GEN_BEFORE" ]]; then
    ok "writer stamps a generation of its own"
else
    bad "writer left no generation token"
fi

# 5. No marker at all — nothing to clobber, write it.
R=$(new_repo absent)
arm_handoff "$R"
run_writer "$R"
check "absent marker: writer succeeds" "$(verdict "$RC")" "wrote"
if grep -q '^BUILTIN-[0-9a-f]\{64\}$' "$R/.claude/litmus-passed.local"; then
    ok "marker written when none existed"
else
    bad "no marker written"
fi

# 6. The marker was CONSUMED since exit 3 (a commit landed) — nothing to clobber
#    either, so a moved generation with no marker must not read as somebody's newer one.
R=$(new_repo consumed)
publish "$R" "markerfromanearlierrun"
arm_handoff "$R"
publish "$R" "someoneelsesmarker"
rm -f "$R/.claude/litmus-passed.local"
run_writer "$R"
check "consumed marker: writer succeeds" "$(verdict "$RC")" "wrote"

# 7. The check and the write are serialized against the ordinary PASS path: a review
#    holding the review lock is publishing its own marker, so we refuse rather than
#    race it. Handoff and baseline stay ARMED — nothing was written, so a retry is
#    valid once the other run releases.
R=$(new_repo locked)
arm_handoff "$R"
ln -s "pid-999999-tok790" "$R/.claude/litmus-review.lock"
run_writer "$R"
check "held review lock refuses" "$(verdict "$RC")" "refused"
check "no marker written under contention" "$(exists "$R/.claude/litmus-passed.local")" "gone"
check "handoff preserved under contention" "$(exists "$R/.claude/builtin-review-prompt-path.local")" "present"
check "baseline preserved under contention" "$(exists "$R/.claude/builtin-review-marker-baseline.local")" "present"
GOT=$(readlink "$R/.claude/litmus-review.lock")
check "lock left for its owner" "$GOT" "pid-999999-tok790"

# 8. A handoff with no baseline cannot be ordered against a concurrent write — refuse.
R=$(new_repo nobaseline)
arm_handoff "$R"
rm -f "$R/.claude/builtin-review-marker-baseline.local"
run_writer "$R"
check "missing baseline refuses" "$(verdict "$RC")" "refused"
check "no marker minted without a baseline" "$(exists "$R/.claude/litmus-passed.local")" "gone"

# 9. A LATER builtin fallback re-armed the handoff (and with it the baseline, which
#    would then describe that run's starting point). Our delayed write must not claim
#    it — and must consume nothing, since the armed pair is the other agent's.
R=$(new_repo rearmed)
publish "$R" "markerpublishedbetweenthetworuns"
arm_handoff "$R" "/tmp/busdriver-review-laterrun"
run_writer "$R"                        # we claim OUR prompt path, not the re-armed one
check "re-armed handoff refuses" "$(verdict "$RC")" "refused"
GOT=$(cat "$R/.claude/litmus-passed.local")
check "marker left alone after re-arm" "$GOT" "markerpublishedbetweenthetworuns"
check "re-armed handoff preserved" "$(exists "$R/.claude/builtin-review-prompt-path.local")" "present"
check "re-armed baseline preserved" "$(exists "$R/.claude/builtin-review-marker-baseline.local")" "present"

# 10. No prompt path argument — the write cannot be attributed to an arming at all.
R=$(new_repo noarg)
arm_handoff "$R"
run_writer "$R" ""
check "missing prompt path refuses" "$(verdict "$RC")" "refused"
check "no marker minted without a prompt path" "$(exists "$R/.claude/litmus-passed.local")" "gone"

# 11. Unchanged by #790: no handoff at all is still a refusal (the forge guard).
R=$(new_repo noarm)
run_writer "$R"
check "no handoff still refuses" "$(verdict "$RC")" "refused"
check "no marker minted without a handoff" "$(exists "$R/.claude/litmus-passed.local")" "gone"

# 12. The state dir is repo-controlled, so a symlink parked at the generation path must
#     not be followed — `>` would truncate whatever it points at.
R=$(new_repo symlinked)
printf 'do not touch me\n' > "$WORK/victim.txt"
arm_handoff "$R"
ln -s "$WORK/victim.txt" "$R/.claude/litmus-marker-gen.local"
run_writer "$R"
check "symlinked generation: writer succeeds" "$(verdict "$RC")" "wrote"
GOT=$(cat "$WORK/victim.txt")
check "symlink target untouched" "$GOT" "do not touch me"
check "generation replaced by a regular file" \
    "$([[ -L "$R/.claude/litmus-marker-gen.local" ]] && echo symlink || echo regular)" "regular"

# 13. The producer side: EVERY marker write in run-review-loop.sh must stamp the
#     generation first, and exit 3 must snapshot it — a publisher that forgets makes
#     its own publication invisible to the delayed writer. Static check; driving a
#     real exit 3 needs every review CLI to be absent.
STAMPS=$(grep -c '^ *publish_marker_gen$' "$LOOP")
WRITES=$(grep -c '> "\$STATE_DIR/litmus-passed.local"' "$LOOP")
check "every marker write stamps a generation" "$STAMPS" "$WRITES"
if grep -q 'builtin-review-marker-baseline.local' "$LOOP"; then
    ok "run-review-loop.sh snapshots the generation at exit 3"
else
    bad "run-review-loop.sh never writes builtin-review-marker-baseline.local"
fi

# 14. BUSDRIVER_STATE_DIR normalization must agree with run-review-loop.sh and
#     review_lock_path, which both reject a leading hyphen. A writer that accepted
#     "-foo" while they normalized it to ".claude" would take the .claude review lock
#     and then look for its handoff and baseline under "-foo", where nothing was ever
#     armed — so every delayed write refuses. Behavioural, not a pattern diff: the
#     writer must find the .claude handoff and publish the .claude marker.
R=$(new_repo hyphenstate)
arm_handoff "$R"
RC=0
OUT=$( (cd "$R" && BUSDRIVER_STATE_DIR=-foo bash "$WRITER" "$PROMPT") 2>&1 ) || RC=$?
check "leading-hyphen state dir: writer succeeds" "$(verdict "$RC")" "wrote"
check "marker published under .claude" "$(exists "$R/.claude/litmus-passed.local")" "present"
check "no -foo state dir created" "$(exists "$R/-foo")" "gone"

# 15. --discard retires a FAILED review's own arming — nothing else does, and an arming
#     left behind lets a later call mint a marker off a review that never passed.
R=$(new_repo discard)
arm_handoff "$R"
run_discard "$R"
check "discard succeeds" "$(verdict "$RC")" "wrote"
check "discard consumes the handoff" "$(exists "$R/.claude/builtin-review-prompt-path.local")" "gone"
check "discard consumes the baseline" "$(exists "$R/.claude/builtin-review-marker-baseline.local")" "gone"
check "discard writes no marker" "$(exists "$R/.claude/litmus-passed.local")" "gone"
check "discard stamps no generation" "$(exists "$R/.claude/litmus-marker-gen.local")" "gone"

# 16. ...and it must not retire somebody else's. A caller doing read-then-delete itself
#     cannot make that check atomic against a concurrent exit 3; --discard holds the
#     review lock and refuses on identity, exactly as the write path does.
R=$(new_repo discard_rearmed)
arm_handoff "$R" "/tmp/busdriver-review-laterrun"
run_discard "$R"
check "discard refuses a re-armed handoff" "$(verdict "$RC")" "refused"
check "re-armed handoff survives discard" "$(exists "$R/.claude/builtin-review-prompt-path.local")" "present"
check "re-armed baseline survives discard" "$(exists "$R/.claude/builtin-review-marker-baseline.local")" "present"

# 17. Discard is serialized like the write: a held review lock refuses it too, so it can
#     never race an exit 3 that is arming the pair while holding that lock.
R=$(new_repo discard_locked)
arm_handoff "$R"
ln -s "pid-999999-tok790" "$R/.claude/litmus-review.lock"
run_discard "$R"
check "held review lock refuses discard" "$(verdict "$RC")" "refused"
check "handoff survives a contended discard" "$(exists "$R/.claude/builtin-review-prompt-path.local")" "present"
# ...and it must say so in its own terms. A contended discard leaves a FAILED review's
# arming live and nothing else retires it, so the refusal has to name the retry rather
# than reuse the write path's "it publishes its own marker" wording (#794).
if printf '%s' "$OUT" | grep -q "STILL ARMED"; then
    ok "contended discard names the live arming"
else
    bad "contended discard does not warn the arming is still live: $OUT"
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
