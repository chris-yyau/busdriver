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

# #290: indirect-write self-bypass vectors. A bare touch of the skip file (and
# touch -t backdating, which also defeats the 30s age heuristic in one shot) was
# the live self-bypass; cp/mv/ln/install are sibling indirect-write channels.
# All now blocked by the extended command-word set in _writes_marker.
SKIPF=".claude/skip-litmus.local"
run_test "#290 touch skip file (self-bypass)" "block" "$(bash_input "touch $SKIPF")"
run_test "#290 touch -t backdate skip file" "block" "$(bash_input "touch -t 202501010000 $SKIPF")"
run_test "#290 cp into marker" "block"        "$(bash_input "cp /tmp/x $MARKER")"
run_test "#290 mv into marker" "block"        "$(bash_input "mv /tmp/x $MARKER")"
run_test "#290 ln -sf into skip file" "block" "$(bash_input "ln -sf /tmp/x $SKIPF")"
run_test "#290 install into skip file" "block" "$(bash_input "install -m 644 /tmp/x $SKIPF")"
run_test "#290 leading-assignment touch still blocks" "block" "$(bash_input "X=1 touch $SKIPF")"
run_test "#290 NAME+=VALUE leading assignment touch blocks" "block" "$(bash_input "X+=1 touch $SKIPF")"
run_test "#290 += var-indirection (M+=marker; touch \$M) blocks" "block" "$(bash_input "M+=$SKIPF ; touch \$M")"
# Leading redirect must not mask the command word (cursor/codex/devin PR #304).
run_test "#290 leading redirect masks touch (>/dev/null touch marker)" "block" "$(bash_input ">/dev/null touch $SKIPF")"
run_test "#290 fd redirect masks touch (2>/dev/null touch marker)" "block" "$(bash_input "2>/dev/null touch $SKIPF")"
run_test "#290 leading redirect masks cp (>out cp x marker)" "block" "$(bash_input ">out.txt cp /tmp/x $MARKER")"
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

BACKSTOP_ARTIFACT=".claude/pr-backstop-verdict.local.json"
run_test "backstop artifact redirect" "block" \
    "$(bash_input "echo x > $BACKSTOP_ARTIFACT")"
run_test "backstop artifact rm" "block" \
    "$(bash_input "rm $BACKSTOP_ARTIFACT")"

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
echo "── #365: unparseable-command block names its real cause ─────────"
# The DECISION is unchanged (still fail-CLOSED block); only the diagnostic differs.
# An unparseable command that merely MENTIONS a marker was reported as "Cannot write
# to gate marker file directly" — an assertion that is often simply false, and one
# that sent operators hunting for a write that never existed (#365). These pin that
# the two paths stay distinguishable, so a future refactor cannot silently re-merge
# the truthful message back into the write-assertion one.
reason_of() {  # $1 = bash command → prints the gate's block reason (empty if allowed)
    printf '%s' "$(bash_input "$1")" | bash "$GATE" 2>/dev/null \
      | { jq -r '.reason // ""' 2>/dev/null || cat; }
}

# A genuine forge keeps the write-assertion message.
if reason_of "touch $SKIPF" | grep -q "Cannot write to gate marker file"; then
    printf "  PASS  %s\n" "#365 real forge keeps the write-assertion message"; PASS=$((PASS + 1))
else
    printf "  FAIL  %s\n" "#365 real forge keeps the write-assertion message"; FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# An unparseable mention gets the fail-closed/could-not-parse message instead —
# and must NOT claim a write was attempted.
UNPARSED_REASON=$(reason_of "git commit -F - <<'EOF'\nOperator's $SKIPF was used\nEOF")
if printf '%s' "$UNPARSED_REASON" | grep -q "could not be parsed"; then
    printf "  PASS  %s\n" "#365 unparseable mention names the parse failure"; PASS=$((PASS + 1))
else
    printf "  FAIL  %s (got: %.60s)\n" "#365 unparseable mention names the parse failure" "$UNPARSED_REASON"; FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

if printf '%s' "$UNPARSED_REASON" | grep -q "Cannot write to gate marker file"; then
    printf "  FAIL  %s\n" "#365 unparseable mention must not assert a write"; FAIL=$((FAIL + 1))
else
    printf "  PASS  %s\n" "#365 unparseable mention must not assert a write"; PASS=$((PASS + 1))
fi
TOTAL=$((TOTAL + 1))

# It still BLOCKS — the message change must not become a behavior change.
run_test "#365 unparseable mention still fails closed" "block" \
    "$(bash_input "git commit -F - <<'EOF'\nOperator's $SKIPF was used\nEOF")"

# NOT TESTED, deliberately: "an unparseable segment followed by a genuine forge in a
# LATER segment". _scan_segment's per-segment reset guards it, but no input reaches it —
# _split_simple_commands splits only on UNQUOTED separators, so every segment inherits
# balanced quote parity and shlex has nothing left to reject; any real imbalance trips
# the whole-command ok=False path FIRST (see the tests above, which is why
# `echo 'unbalanced ; touch <marker>` correctly reports a parse failure: the ; is inside
# the quote, so there is no second command). The reset stays as hygiene in case the two
# parsers ever diverge; writing a test that only appears to cover it would be worse than
# naming the gap here.

# The message must not tell the AGENT to create a skip file — it is a user-only escape
# hatch, and every sibling message in the gate says so. Pins the wording against drift
# that would nudge a cooperative agent toward the self-bypass this detector deters.
if printf '%s' "$UNPARSED_REASON" | grep -qi "Do NOT create or re-touch a skip file yourself"; then
    printf "  PASS  %s\n" "#365 unparseable message keeps the user-only skip framing"; PASS=$((PASS + 1))
else
    printf "  FAIL  %s\n" "#365 unparseable message keeps the user-only skip framing"; FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))

# #290: legit touch/cp/mv of NON-marker files must still be allowed (no false
# positives from the extended command-word set).
run_test "#290 allow touch non-marker src" "allow" "$(bash_input "touch src/newfile.js")"
run_test "#290 allow cp non-marker files" "allow"  "$(bash_input "cp a.txt b.txt")"
run_test "#290 allow mv non-marker files" "allow"  "$(bash_input "mv old.js new.js")"
# The verb appears only as an ARGUMENT to a read (not the command word) → allow.
# This is the read-only contract the command-word-position check preserves.
run_test "#290 allow grep 'touch' pattern over marker (read)" "allow" "$(bash_input "grep touch $MARKER")"
run_test "#290 allow read marker piped to grep cp" "allow" "$(bash_input "cat $MARKER | grep cp")"
# Documented residual (ADR 0006 addendum): a wrapper-hidden indirect write
# (sudo/env prefix) is NOT caught — out of scope for the cooperative-agent threat.
run_test "#290 wrapper sudo touch is residual (allow)" "allow" "$(bash_input "sudo touch $SKIPF")"
# Leading redirect + a genuine READ command word stays allowed (no false positive).
run_test "#290 allow leading redirect + read (>/dev/null cat marker)" "allow" "$(bash_input ">/dev/null cat $MARKER")"

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
