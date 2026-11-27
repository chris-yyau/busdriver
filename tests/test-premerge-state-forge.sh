#!/usr/bin/env bash
# Regression tests for CHR-40 — the pre-merge gate's local state files get the same
# marker-forge guard as their siblings.
#
# skip-litmus.local and skip-design-review.local were on marker_check.py's MARKER_FILES;
# skip-pr-grind.local, the operator's pre-merge escape hatch, was not, and neither was
# .merge-bypass-pending.local, the claim post-merge-confirm-bypass.sh reads to decide
# whether that escape hatch is spent. Both are now listed, and so are two of the
# per-repo merge-path opt-ins the operator places by hand (section D). Section E pins
# the block message for them (#1180).
#
# Three sides are pinned, and all three are needed:
#   A. direct writes, deletes and indirect-verb writes of both files BLOCK
#   B. reads and mentions (the operator instruction pr-grind prints) still ALLOW
#   C. design-clear.sh --skip drains a spent skip-pr-grind.local, since A now blocks a
#      bare rm of it, and refuses the pending claim, whose removal leaves the bypass armed
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
DRAIN="$ROOT/scripts/design-clear.sh"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

# The classifier's own verdict, not the gate's decision, so pending-review state cannot
# decide the outcome. Same payload shape as test-marker-loop-binding-638.sh.
verdict() { # <tool> <field> <value> -> the verdict line, or ERROR
    local payload
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":sys.argv[1],"tool_input":{sys.argv[2]:sys.argv[3]}}))' \
        "$1" "$2" "$3" 2>/dev/null) || { printf 'ERROR'; return; }
    python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null || printf 'ERROR'
}

assert_block() { # <tool> <field> <value> <marker> <label>
    local got
    got="$(verdict "$1" "$2" "$3")"
    if [[ "$got" == "BLOCK_MARKER|$4" ]]; then
        ok "$5"
    else
        no "$5" "got=${got:-<empty>} — expected BLOCK_MARKER|$4"
    fi
}

assert_ok() { # <command> <label>
    local got
    got="$(verdict Bash command "$1")"
    if [[ "$got" == "OK|" ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — a read or a mention must stay allowed"
    fi
}

echo "── A. both pre-merge state files are forge-guarded ──"

for m in skip-pr-grind.local .merge-bypass-pending.local; do
    p=".claude/$m"
    assert_block Write file_path "/repo/$p" "$m" "Write $m"
    assert_block Edit file_path "/repo/$p" "$m" "Edit $m"
    assert_block MultiEdit file_path "/repo/$p" "$m" "MultiEdit $m"
    assert_block Bash command "touch $p" "$m" "touch $m"
    assert_block Bash command "echo x > $p" "$m" "redirect into $m"
    assert_block Bash command "echo x | tee $p" "$m" "tee into $m"
    assert_block Bash command "rm -f $p" "$m" "rm $m"
    assert_block Bash command "cp /tmp/x $p" "$m" "cp onto $m"
    assert_block Bash command "touch -t 202601010000 $p" "$m" "backdated touch of $m"
done

# Positive control: the sibling the parity is with. If this fails the harness is broken,
# not the new rows.
assert_block Bash command "touch .claude/skip-litmus.local" skip-litmus.local "control: touch skip-litmus.local"

echo "── B. reads and mentions stay allowed ──"

for m in skip-pr-grind.local .merge-bypass-pending.local; do
    p=".claude/$m"
    assert_ok "cat $p" "cat $m"
    assert_ok "test -f $p" "test -f $m"
    assert_ok "[ -e $p ] && echo armed" "[ -e ] $m"
    assert_ok "stat -f %m $p" "stat $m"
done
# The operator-only escape pr-grind prints (completion.md) names the skip file in a
# touch line. As a quoted string it is a mention, not a write.
assert_ok "printf '%s\\n' '  touch <PROJECT_ROOT>/.claude/skip-pr-grind.local   (wait at least 30s before merging)'" \
    'the printed operator instruction is a mention'

echo "── D. the operator's merge-path opt-ins are forge-guarded ──"

for m in skip-baseref-check.local pr-grind-auto-admin-solo.local; do
    p=".claude/$m"
    assert_block Write file_path "/repo/$p" "$m" "Write $m"
    assert_block Edit file_path "/repo/$p" "$m" "Edit $m"
    assert_block Bash command "touch $p" "$m" "touch $m"
    assert_block Bash command "echo x > $p" "$m" "redirect into $m"
    assert_block Bash command "rm -f $p" "$m" "rm $m"
    assert_block Bash command "cp /tmp/x $p" "$m" "cp onto $m"
    assert_ok "test -f $p" "test -f $m"
    assert_ok "stat -f %m $p" "stat $m"
done

echo "── C. the design-clear drain ──"

# Armed from SCRIPT code, never from a tool call: A is exactly what blocks a tool call.
TMP="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
git -C "$TMP" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
mkdir -p "$TMP/.claude"

drain() { ( cd "$TMP" && bash "$DRAIN" "$@" 2>&1 ); }

: >"$TMP/.claude/skip-pr-grind.local"
OUT="$(drain --skip skip-pr-grind.local --yes)"; CODE=$?
if [ "$CODE" -eq 0 ] && [ ! -e "$TMP/.claude/skip-pr-grind.local" ] \
   && grep -q '"event": *"skip-marker-cleared"' "$TMP/.claude/bypass-log.jsonl" 2>/dev/null; then
    ok 'drains an armed skip-pr-grind.local, with an audit event'
else
    no 'drains an armed skip-pr-grind.local, with an audit event' "exit=$CODE out=$OUT"
fi

printf '31 0\n' >"$TMP/.claude/.merge-bypass-pending.local"
OUT="$(drain --skip .merge-bypass-pending.local --yes)"; CODE=$?
if [ "$CODE" -ne 0 ] && [ -e "$TMP/.claude/.merge-bypass-pending.local" ]; then
    ok 'refuses the pending merge-bypass claim'
else
    no 'refuses the pending merge-bypass claim' "exit=$CODE out=$OUT"
fi

echo "── E. the gate's message names the right escape (#1180) ──"

# The real gate, so the message text is pinned, not just the verdict.
GATE="$ROOT/hooks/gate-scripts/pre-implementation-gate.sh"
reason() { # <command> -> the block reason
    python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2],"hook_event_name":"PreToolUse"}))' "$1" "$TMP" \
        | ( cd "$TMP" && bash "$GATE" 2>/dev/null ) \
        | python3 -c 'import json,sys;print(json.load(sys.stdin).get("reason",""))' 2>/dev/null
}
for pair in "touch .claude/skip-pr-grind.local|Only the user creates this file" \
            "rm .claude/.merge-bypass-pending.local|nothing to do by hand" \
            "touch .claude/pr-grind-auto-admin-solo.local|consent only the user gives" \
            "rm .claude/skip-baseref-check.local|creates or removes it"; do
    c="${pair%%|*}"; want="${pair#*|}"
    r="$(reason "$c")"
    if [[ "$r" == *"$want"* && "$r" != *skip-litmus.local* && "$r" != */litmus* ]]; then ok "message: $c"
    else no "message: $c" "reason=${r:-<empty>}"; fi
done

printf '\n════ premerge-state-forge: %d passed, %d failed ════\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
