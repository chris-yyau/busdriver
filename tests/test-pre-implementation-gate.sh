#!/usr/bin/env bash
# Tests for the pre-implementation-gate marker-forge detector (issue #227).
#
# The gate blocks Bash commands that WRITE to a gate marker file (redirect
# target, or tee/rm operand) and Write/Edit/MultiEdit whose file_path names a
# marker — while ALLOWING commands that merely read or mention a marker name.
# Detection uses a real shell tokenizer (shlex), so quoted and multi-operand
# targets are caught without false-positiving benign commands.
#
# Usage: bash tests/test-pre-implementation-gate.sh
# Exit: 0 if all pass, 1 if any fail.

# SC2312: run_test deliberately captures stdout via $(...) and checks the gate's
# JSON decision, not the pipeline exit status — masking is intentional here.
# shellcheck disable=SC2312
set -euo pipefail
cd "$(dirname "$0")/.."

GATE="hooks/gate-scripts/pre-implementation-gate.sh"
MARKER=".claude/litmus-passed.local"
ARTIFACT=".claude/pr-codex-lead.local.json"

PASS=0
FAIL=0
TOTAL=0

run_test() {
    local name="$1" expected="$2" input="$3"
    TOTAL=$((TOTAL + 1))
    local output exit_code
    output=$(printf '%s' "$input" | bash "$GATE" 2>/dev/null) && exit_code=0 || exit_code=$?

    local got="allow"
    if [[ "$exit_code" -ne 0 ]] && [[ -z "$output" ]]; then
        got="crash"
    elif echo "$output" | grep -q '"block"' 2>/dev/null; then
        got="block"
    elif echo "$output" | grep -q '"ask"' 2>/dev/null; then
        got="ask"
    fi

    if [[ "$got" == "$expected" ]]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"
        FAIL=$((FAIL + 1))
    fi
}

bash_input() {
    # Emit a Bash-tool hook JSON payload for the given command (arg already
    # JSON-escaped by the caller).
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"
}

echo "── marker-forge: WRITE vectors must BLOCK ───────────────────────"

# 1-4: the four documented bypasses (PR #225 dogfood).
run_test "bypass: single-quoted redirect target" "block" \
    "$(bash_input "echo ok > '$MARKER'")"
run_test "bypass: multi-operand tee" "block" \
    "$(bash_input "tee /tmp/log $MARKER")"
run_test "bypass: multi-operand rm" "block" \
    "$(bash_input "rm -f a $MARKER")"
run_test "bypass: fd-interleave (2>&1) before rm operand" "block" \
    "$(bash_input "rm -f a 2>&1 $MARKER")"

# 4a-4f: codex-found bypasses from the PR #225 dogfood review of the tokenizer
# (quoted/escaped separators, # comments, redirect-only assignment indirection,
# clobber redirect). These regress the quote-aware segmenter.
run_test "bypass: quoted-separator rm operand" "block" \
    "$(bash_input "rm ';' $MARKER")"
run_test "bypass: escaped-separator rm operand" "block" \
    "$(bash_input "rm \\\\; $MARKER")"
run_test "bypass: comment swallows newline then rm" "block" \
    "$(bash_input "echo safe # comment\nrm $MARKER")"
run_test "bypass: redirect-only assignment then rm \$var" "block" \
    "$(bash_input "> /dev/null m=$MARKER ; rm \$m")"
run_test "bypass: clobber redirect >| to marker" "block" \
    "$(bash_input "echo x >| $MARKER")"
run_test "allow: separator inside double-quoted echo arg" "allow" \
    "$(bash_input "echo \\\"see ; rm $MARKER\\\"")"

# 5-17: other write/forge vectors.
run_test "plain redirect" "block"        "$(bash_input "echo PASS > $MARKER")"
run_test "glued redirect (no spaces)" "block" "$(bash_input "echo x>$MARKER")"
run_test "append redirect" "block"       "$(bash_input "echo x >> $MARKER")"
run_test "redirect stdout+stderr (&>)" "block" "$(bash_input "echo x &> $MARKER")"
run_test "double-quoted redirect target" "block" \
    "$(bash_input "echo x > \\\"$MARKER\\\"")"
run_test "pipe into tee" "block"         "$(bash_input "echo x | tee $MARKER")"
run_test "plain rm (deletion forgery)" "block" "$(bash_input "rm $MARKER")"
run_test "subshell redirect" "block"     "$(bash_input "( echo x > $MARKER )")"
run_test "multiline: rm on second line" "block" \
    "$(bash_input "echo safe\nrm $MARKER")"
run_test "sudo rm" "block"               "$(bash_input "sudo rm -f $MARKER")"
run_test "wrapper: sudo with flag (-n) before rm" "block" \
    "$(bash_input "sudo -n rm $MARKER")"
run_test "wrapper: env assignment before rm" "block" \
    "$(bash_input "env FOO=bar rm $MARKER")"
run_test "wrapper: timeout with arg before rm" "block" \
    "$(bash_input "timeout 5 rm $MARKER")"
run_test "git rm marker (index deletion)" "block" \
    "$(bash_input "git rm $MARKER")"
run_test "quoted arg with < then marker operand (rm)" "block" \
    "$(bash_input "rm 'a<b' $MARKER")"
run_test "quoted arg with < then marker operand (tee)" "block" \
    "$(bash_input "tee 'a<b' $MARKER")"
run_test "ANSI-C quoted redirect target (\$'...')" "block" \
    "$(bash_input "echo x > \$'$MARKER'")"
run_test "ANSI-C quoted rm operand (\$'...')" "block" \
    "$(bash_input "rm \$'$MARKER'")"
run_test "parameter-expansion default as redirect target" "block" \
    "$(bash_input "echo x > \${V:-$MARKER}")"
run_test "parameter-expansion default as rm operand" "block" \
    "$(bash_input "rm \${V:-$MARKER}")"
run_test "quote-concatenated redirect target (split basename)" "block" \
    "$(bash_input "echo x > .claude/'litmus-pass''ed.local'")"
run_test "quote-concatenated rm operand (split basename)" "block" \
    "$(bash_input "rm .claude/lit'mus-passed.lo'cal")"
run_test "unparseable cmd mentioning marker (fail-closed)" "block" \
    "$(bash_input "echo \\\"x $MARKER")"
run_test "variable-indirection redirect (m=marker; > \$m)" "block" \
    "$(bash_input "m=$MARKER; echo PASS > \$m")"
run_test "variable-indirection rm (m=marker; rm \$m)" "block" \
    "$(bash_input "m=$MARKER; rm \$m")"
run_test "backslash-newline continuation rejoined (rm)" "block" \
    '{"tool_name":"Bash","tool_input":{"command":"rm \\\n.claude/litmus-passed.local"}}'
run_test "backslash-newline continuation rejoined (split basename)" "block" \
    '{"tool_name":"Bash","tool_input":{"command":"echo x > .claude/litmus-passed.lo\\\ncal"}}'
run_test "variable write then later reassignment (ordering)" "block" \
    "$(bash_input "m=$MARKER; echo PASS > \$m; m=/tmp/log")"
run_test "IFS field-split obfuscation (rm\${IFS}marker)" "block" \
    "$(bash_input "rm\${IFS}$MARKER")"
run_test "IFS field-split obfuscation (tee multi-operand)" "block" \
    "$(bash_input "tee\${IFS}/tmp/log\${IFS}$MARKER")"
run_test "bare basename redirect" "block" "$(bash_input "echo PASS > litmus-passed.local")"
run_test "PR artifact (.local.json) redirect" "block" \
    "$(bash_input "echo x > $ARTIFACT")"
run_test "PR artifact (.local.json) rm" "block" \
    "$(bash_input "rm $ARTIFACT")"

echo ""
echo "── benign / read-only: must ALLOW ───────────────────────────────"

run_test "rm unrelated && echo marker (quoted)" "allow" \
    "$(bash_input "rm /tmp/x && echo '$MARKER'")"
run_test "redirect to unrelated ; echo marker" "allow" \
    "$(bash_input "echo done > /tmp/log ; echo $MARKER")"
run_test "read: test -f marker" "allow"  "$(bash_input "test -f $MARKER")"
run_test "read: [ -f marker ]" "allow"   "$(bash_input "[ -f $MARKER ]")"
run_test "read: cat marker" "allow"      "$(bash_input "cat $MARKER")"
run_test "read: input redirect (< marker)" "allow" "$(bash_input "grep x < $MARKER")"
run_test "marker as plain echo arg" "allow" "$(bash_input "echo $MARKER")"
run_test "rm unrelated ; echo marker" "allow" "$(bash_input "rm /tmp/x ; echo $MARKER")"
run_test "marker named in quoted msg, unrelated redirect" "allow" \
    "$(bash_input "echo \\\"see $MARKER for details\\\" > /tmp/notes")"
run_test "read: cat marker piped to tee elsewhere" "allow" \
    "$(bash_input "cat $MARKER | tee /tmp/out")"
run_test "rm with quoted-< arg, no marker" "allow" \
    "$(bash_input "rm 'a<b' /tmp/x")"
run_test "ANSI-C quoted marker as echo arg (read)" "allow" \
    "$(bash_input "echo \$'$MARKER'")"
run_test "marker-substring filename under non-rm/tee cmd (tar)" "allow" \
    "$(bash_input "tar czf $MARKER.tgz src")"
run_test "unparseable cmd, no marker mentioned (allow)" "allow" \
    "$(bash_input "echo \\\"unbalanced quote")"
run_test "variable redirect to non-marker, marker only in message" "allow" \
    "$(bash_input "L=/tmp/app.log; echo note-$MARKER >> \$L")"
run_test "variable safe-first then reassigned to marker (no marker write)" "allow" \
    "$(bash_input "m=/tmp/log; echo PASS > \$m; m=$MARKER")"
run_test "name=value as echo argument, not an assignment" "allow" \
    "$(bash_input "echo m=$MARKER; rm \$m")"
run_test "IFS-split marker as echo arg (read, not write)" "allow" \
    "$(bash_input "echo\${IFS}$MARKER")"
run_test "read: grep quoted rm|tee pattern over marker" "allow" \
    "$(bash_input "grep -E \\\"rm|tee\\\" $MARKER")"
run_test "no marker at all" "allow"      "$(bash_input "rm -rf /tmp/junk")"

echo ""
echo "── Write/Edit/MultiEdit marker file_path must BLOCK ─────────────"

run_test "Write marker path" "block" \
    "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$MARKER\"}}"
run_test "Edit marker path" "block" \
    "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$MARKER\"}}"
run_test "MultiEdit marker path" "block" \
    "{\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"$ARTIFACT\"}}"
run_test "Read marker path (not gated)" "allow" \
    "{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$MARKER\"}}"

echo ""
echo "── write-review-marker.sh allowlist ─────────────────────────────"

run_test "write-review-marker via non-litmus path blocked" "block" \
    "$(bash_input "bash /tmp/evil/write-review-marker.sh")"
run_test "write-review-marker via litmus/scripts path allowed" "allow" \
    "$(bash_input "bash skills/litmus/scripts/write-review-marker.sh")"

echo ""
echo "═══════════════════════════════════════════════════════════════"
printf "Results: %d/%d passed" "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then
    printf " (%d FAILED)\n" "$FAIL"
    exit 1
else
    printf " (all passed)\n"
    exit 0
fi
