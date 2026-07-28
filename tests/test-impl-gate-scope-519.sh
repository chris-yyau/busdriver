#!/usr/bin/env bash
# Tests for issue #519 — pre-implementation gate composition fixes.
#
# Covers the three items shipped (1 was declined; see ADR 0031):
#   item 4  file-mod classification is token-level, so a verb inside a QUOTED
#           operand no longer reads as a file write, while wrapper-hidden real
#           writes stay blocked and an unparseable command falls back to the old
#           regexes (never to "allow").
#   item 3  the skip file is a LEASE (N uses / bounded window), it is spent only
#           by genuinely-gated operations, and it expires.
#   item 2  the block message points at the audited design-clear.sh release
#           rather than a bare `rm` of the gate's own audit trail.
#
# Each test drives the REAL gate against a REAL throwaway repo with a REAL armed
# marker — a guard whose failure branch has never been observed is not a guard.
#
# Usage: bash tests/test-impl-gate-scope-519.sh
# Exit: 0 if all pass, 1 if any fail.

# SC2312: decisions are read from captured stdout, not pipeline status.
# shellcheck disable=SC2312
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$PWD"
GATE="$REPO_ROOT/hooks/gate-scripts/pre-implementation-gate.sh"

PASS=0; FAIL=0

ok() { printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no() { printf "  FAIL  %s (%s)\n" "$1" "$2"; FAIL=$((FAIL + 1)); }

check() {   # <name> <expected: allow|block> <actual-output>
    local name="$1" expected="$2" out="$3" got="allow"
    case "$out" in *'"block"'*) got="block" ;; esac
    if [ "$got" = "$expected" ]; then ok "$name"; else no "$name" "expected=$expected got=$got"; fi
}

# ── A throwaway repo with ONE armed (pending) design-review marker ───────────
# Everything below needs a pending review, or the gate fast-allows and proves
# nothing. Built once and reused; each test resets the skip/lease state.
WORK="$(mktemp -d)" || WORK=""
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
    echo "  FAIL  could not create a temp fixture dir — refusing to run" >&2
    exit 1
fi
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q 2>/dev/null
git -C "$WORK" config user.email t@t.t
git -C "$WORK" config user.name t
mkdir -p "$WORK/docs/plans" "$WORK/.claude" "$WORK/src"
printf '# plan\n' >"$WORK/docs/plans/thing.md"
bash "$REPO_ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh" arm "$WORK/docs/plans/thing.md" >/dev/null 2>&1

# Confirm the fixture actually blocks — if arming silently failed, every "block"
# assertion below would pass vacuously and the suite would certify nothing.
BASE="$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/src/impl.py"}}' "$WORK" "$WORK" \
        | (cd "$WORK" && bash "$GATE") 2>/dev/null)"
case "$BASE" in
    *'"block"'*) ok "fixture: an armed marker blocks an implementation write" ;;
    *) no "fixture: an armed marker blocks an implementation write" "gate allowed — fixture is broken, remaining results are meaningless"
       printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"; exit 1 ;;
esac

bash_decision() {   # <command>  -> gate stdout
    python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],
                  "tool_input":{"command":sys.argv[2]}}))' "$WORK" "$1" \
    | (cd "$WORK" && bash "$GATE") 2>/dev/null
}

echo "── item 4: read-only commands that MENTION a verb must be ALLOWED ──"

check "grep whose PATTERN contains 'rm |mv '" allow \
    "$(bash_decision "grep -nE 'rm |mv |truncate' script.sh")"
check "echo whose LABEL contains 'mv '" allow \
    "$(bash_decision "bash -c 'echo \"T3 (mv FAILS): ...\"'")"
check "read-only sed -n" allow "$(bash_decision "sed -n '1,10p' file.txt")"
check "grep -i with 'sed' as the search string" allow \
    "$(bash_decision "grep -i sed notes.txt")"
check "plain listing" allow "$(bash_decision "ls -la")"
# A verb as plain DATA in a read-only command. This is why the classifier peels wrapper
# preambles instead of scanning every token: an all-token scan catches `sudo rm -rf src`
# but also misreads these.
check "grep with a verb as the search string" allow "$(bash_decision "grep dd notes.txt")"
check "echo naming a verb" allow "$(bash_decision "echo rmdir")"
check "piping into grep for a verb" allow "$(bash_decision "git log --oneline | grep rm")"
# #519 false positive 3: a probe DEFINING a function named mv. The paren split leaves
# a bare `mv` segment that reads as an invocation unless the header is stripped.
check "defining a shell function named mv" allow \
    "$(bash_decision "mv() { echo harmless; }")"
check "defining mv then calling rm still blocks" block \
    "$(bash_decision "mv() { echo hi; } ; rm x")"
# -c is a COUNT flag for grep, not "execute this string" — recursing on every -c
# operand would resurrect the quoted-operand false positive this change removes.
check "grep -c whose pattern contains 'rm '" allow "$(bash_decision "grep -c 'rm ' file.txt")"

echo "── item 4: real writes must still BLOCK ────────────────────────────"

check "bare rm" block "$(bash_decision "rm -rf src")"
check "wrapper-hidden rm (sudo)" block "$(bash_decision "sudo rm -rf src")"
check "wrapper-hidden mv (nohup)" block "$(bash_decision "nohup mv a b")"
check "leading assignment then rm" block "$(bash_decision "FOO=1 rm x")"
check "sed -i in place" block "$(bash_decision "sed -i 's/a/b/' f")"
check "sed -i.bak in place" block "$(bash_decision "sed -i.bak 's/a/b/' f")"
check "tee" block "$(bash_decision "cat x | tee out.txt")"
check "second segment writes" block "$(bash_decision "ls && rm x")"
check "timeout wrapper hiding rm" block "$(bash_decision "timeout 5 rm x")"
check "xargs running rm" block "$(bash_decision "echo hi | xargs rm")"
check "find -exec rm" block "$(bash_decision "find . -exec rm {} ;")"
check "find -delete" block "$(bash_decision "find . -delete")"
# Executed-string operands. Tokenizing alone reduces these to inert single tokens, so
# each was a live fail-open in the first cut of this change — caught by codex review.
# Note the shape is IDENTICAL to the allowed `bash -c 'echo "(mv FAILS)"'` above; only
# the inner program differs, which is why the operand must be re-classified as shell
# source rather than pattern-matched.
check "bash -c with an rm payload" block "$(bash_decision "bash -c 'rm -rf src'")"
check "eval with an rm payload" block "$(bash_decision "eval 'rm -rf src'")"
check "command substitution running rm" block "$(bash_decision "echo \"\$(rm -rf src)\"")"
check "wrapper + shell -c payload" block "$(bash_decision "sudo bash -c 'rm x'")"
# The unparseable path must fall back to the REGEXES (block), never to "allow" —
# this is the one branch where a tokenizer bug could become a fail-open.
check "unparseable (apostrophe in prose) + rm falls back to blocking" block \
    "$(bash_decision "git commit -m \"the operator's skip file\" && rm x")"

echo "── item 3: the skip file is a lease ────────────────────────────────"

arm_skip() {   # <age-seconds>
    rm -rf "$WORK/.claude/.skip-design-review-lease.d"
    : >"$WORK/.claude/skip-design-review.local"
    # Backdate so the >=30s anti-self-bypass floor is satisfied without sleeping.
    local when
    when="$(python3 -c 'import sys,time;print(time.time()-float(sys.argv[1]))' "$1")"
    python3 -c 'import os,sys;t=float(sys.argv[2]);os.utime(sys.argv[1],(t,t))' \
        "$WORK/.claude/skip-design-review.local" "$when"
}

write_decision() {   # -> gate stdout for a gated implementation Write
    printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/src/impl.py"}}' "$WORK" "$WORK" \
    | (cd "$WORK" && bash "$GATE") 2>/dev/null
}

# The old gate consumed the skip on the FIRST gated write. The whole point of the
# lease is that the second, third, ... still pass on ONE operator touch.
arm_skip 120
r1="$(write_decision)"; r2="$(write_decision)"; r3="$(write_decision)"
check "lease use 1 allows" allow "$r1"
check "lease use 2 allows (old gate consumed after 1)" allow "$r2"
check "lease use 3 allows" allow "$r3"

# ...and the count is real, not unbounded. Uses are immutable <mtime>.<n> slot dirs:
# a mutable counter would let two concurrent gates both read k and both write k+1,
# silently overshooting the ceiling.
lease_uses() { find "$WORK/.claude/.skip-design-review-lease.d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
if [ "$(lease_uses)" = "3" ]; then ok "lease records 3 uses as atomic slots"
else no "lease records 3 uses as atomic slots" "got $(lease_uses)"; fi

# A read-only Bash must NOT spend a use — this is the "any intervening tool call
# burns it" sharp edge the late invocation fixes.
before="$(lease_uses)"
bash_decision "ls -la" >/dev/null
after="$(lease_uses)"
if [ "$before" = "$after" ]; then ok "a read-only command does not spend a lease use"
else no "a read-only command does not spend a lease use" "$before -> $after"; fi

# An EXEMPT write (the design doc itself) must not spend one either.
printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/docs/plans/thing.md"}}' "$WORK" "$WORK" \
    | (cd "$WORK" && bash "$GATE") >/dev/null 2>&1
after2="$(lease_uses)"
if [ "$before" = "$after2" ]; then ok "an exempt design-doc write does not spend a lease use"
else no "an exempt design-doc write does not spend a lease use" "$before -> $after2"; fi

# Exhaustion: burn the budget, then confirm the next write blocks AND the file is gone.
arm_skip 120
i=0; while [ "$i" -lt 20 ]; do write_decision >/dev/null; i=$((i + 1)); done
check "write 21 blocks (lease exhausted)" block "$(write_decision)"
if [ -f "$WORK/.claude/skip-design-review.local" ]; then no "exhausted lease removes the skip file" "file still present"
else ok "exhausted lease removes the skip file"; fi
# ...but the SLOTS must survive. Deleting them here is a TOCTOU: a concurrent gate that
# already passed the skip-file/mtime checks would mkdir -p a fresh directory, claim slot
# 1 under the same mtime, and be granted a 21st use.
if [ "$(lease_uses)" = "20" ]; then ok "exhausted lease KEEPS its slots (anti-TOCTOU)"
else no "exhausted lease KEEPS its slots (anti-TOCTOU)" "got $(lease_uses)"; fi

# FAIL-CLOSED: if a use cannot be RECORDED it cannot be BOUNDED, so an unwritable
# lease dir must refuse the bypass rather than grant an unlimited one until expiry.
arm_skip 120
rm -rf "$WORK/.claude/.skip-design-review-lease.d"
: >"$WORK/.claude/.skip-design-review-lease.d"          # a plain file: mkdir -p will fail
check "an unrecordable lease refuses the bypass (fail-closed)" block "$(write_decision)"
rm -f "$WORK/.claude/.skip-design-review-lease.d"

# FAIL-CLOSED on an unwritable audit log. The docs promise every lease use is
# recorded; a silent `|| true` would turn an audited hatch into an unaudited one, so
# the promise is enforced rather than merely stated (same rule design-clear.sh applies).
arm_skip 120
mv "$WORK/.claude/bypass-log.jsonl" "$WORK/.claude/bypass-log.bak" 2>/dev/null || true
mkdir -p "$WORK/.claude/bypass-log.jsonl"    # a directory: the append cannot succeed
check "an unloggable lease use refuses the bypass (fail-closed)" block "$(write_decision)"
rmdir "$WORK/.claude/bypass-log.jsonl" 2>/dev/null || true

# A SYMLINKED log must refuse too. A plain `>>` follows symlinks, so pointing the log
# at /dev/null would make the append "succeed" while retaining nothing — the check
# would then read that as proof of a durable record and grant an unlogged lease.
arm_skip 120
ln -sfn /dev/null "$WORK/.claude/bypass-log.jsonl"
check "a symlinked audit log refuses the bypass (fail-closed)" block "$(write_decision)"
rm -f "$WORK/.claude/bypass-log.jsonl"
mv "$WORK/.claude/bypass-log.bak" "$WORK/.claude/bypass-log.jsonl" 2>/dev/null || true

# Expiry: an old file is refused however few uses it has left.
arm_skip 7200
check "an over-age skip file blocks (lease expired)" block "$(write_decision)"
if [ -f "$WORK/.claude/skip-design-review.local" ]; then no "expired lease removes the skip file" "file still present"
else ok "expired lease removes the skip file"; fi

# The >=30s anti-self-bypass floor must survive the change to a lease.
arm_skip 2
check "a just-created skip file is refused (self-bypass floor intact)" block "$(write_decision)"

# The ledger is what BOUNDS the lease, so it is gate state like the skip file itself.
# Unprotected, the agent could spend one use on `rm -rf <ledger>` and reset the ceiling
# to zero — an unbounded lease that merely looks bounded.
check "deleting the lease ledger is blocked" block \
    "$(bash_decision "rm -rf .claude/.skip-design-review-lease.d")"
check "redirecting into the lease ledger is blocked" block \
    "$(bash_decision "echo x > .claude/.skip-design-review-lease.d/1")"
# Hardening the APPEND is worth nothing if the FILE can be erased for free — writes
# under $STATE_DIR are otherwise SAFE and a bare rm of one hits the F9 exemption.
check "deleting the bypass audit log is blocked" block \
    "$(bash_decision "rm -f .claude/bypass-log.jsonl")"
check "truncating the bypass audit log is blocked" block \
    "$(bash_decision "echo x > .claude/bypass-log.jsonl")"
check "READING the bypass audit log is still allowed" allow \
    "$(bash_decision "cat .claude/bypass-log.jsonl")"
# truncate/unlink erase content with an ordinary bare command and were in neither the
# old regexes nor the forge detector, so they could wipe the trail for free.
check "truncate on the audit log is blocked" block \
    "$(bash_decision "truncate -s 0 .claude/bypass-log.jsonl")"
check "unlink on the audit log is blocked" block \
    "$(bash_decision "unlink .claude/bypass-log.jsonl")"
check "dd blanking the audit log is blocked" block \
    "$(bash_decision "dd if=/dev/null of=.claude/bypass-log.jsonl")"
# rmdir on a spent slot would let it be reclaimed, extending the ceiling indefinitely.
check "rmdir on a spent lease slot is blocked" block \
    "$(bash_decision "rmdir .claude/.skip-design-review-lease.d/1.1")"

echo "── item 2: block message points at the audited release path ────────"

rm -f "$WORK/.claude/skip-design-review.local"; rm -rf "$WORK/.claude/.skip-design-review-lease.d"
MSG="$(write_decision)"
case "$MSG" in
    *design-clear.sh*) ok "block message names design-clear.sh" ;;
    *) no "block message names design-clear.sh" "hint missing" ;;
esac
case "$MSG" in
    *"drain if abandoned: rm "*) no "block message no longer invites a bare rm" "rm hint still present" ;;
    *) ok "block message no longer invites a bare rm" ;;
esac

echo "── item 2: the release RECORDS what residual was accepted ─────────"

# The point of routing operators to design-clear.sh instead of `rm` is that the
# trail survives the release. A doc approved under DEGRADED coverage keeps its PASS
# withheld (#355), so a release is the only way forward — and the event must name
# the coverage that was accepted, or the record does not answer the question #519
# asked ("which lenses were absent, and who accepted the residual").
CLEARWORK="$(mktemp -d)" || CLEARWORK=""
if [ -z "$CLEARWORK" ] || [ ! -d "$CLEARWORK" ]; then
    no "clear event records the DEGRADED coverage it released" "no temp dir"
    printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"; exit 1
fi
git -C "$CLEARWORK" init -q 2>/dev/null
git -C "$CLEARWORK" config user.email t@t.t
git -C "$CLEARWORK" config user.name t
mkdir -p "$CLEARWORK/docs/plans"
printf '# plan\n<!-- design-review-coverage: DEGRADED 1/3 (reviewer_2=runtime-failed) -->\n' \
    >"$CLEARWORK/docs/plans/p.md"
bash "$REPO_ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh" arm "$CLEARWORK/docs/plans/p.md" >/dev/null 2>&1
(cd "$CLEARWORK" && bash "$REPO_ROOT/scripts/design-clear.sh" "$CLEARWORK/docs/plans/p.md" --yes) >/dev/null 2>&1
EVT="$(tail -1 "$CLEARWORK/.claude/bypass-log.jsonl" 2>/dev/null || true)"
case "$EVT" in
    *'"coverage"'*DEGRADED*) ok "clear event records the DEGRADED coverage it released" ;;
    *) no "clear event records the DEGRADED coverage it released" "got: ${EVT:-<no event>}" ;;
esac
# ...and still records HOW it was authorized, which the coverage field must not displace.
case "$EVT" in
    *'"confirmed"'*) ok "clear event still records how the release was authorized" ;;
    *) no "clear event still records how the release was authorized" "field missing" ;;
esac
rm -rf "$CLEARWORK"

echo "── the hardened audit appender ────────────────────────────────────"
if python3 -I "$REPO_ROOT/hooks/gate-scripts/lib/audit_append.py" --self-check >/dev/null 2>&1; then
    ok "audit_append self-check (symlinked log / symlinked prefix / torn line all refuse)"
else
    no "audit_append self-check" "see: python3 hooks/gate-scripts/lib/audit_append.py --self-check"
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
