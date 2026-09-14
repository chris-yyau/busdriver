#!/usr/bin/env bash
# tests/test-agy-stream-transport.sh — agy >=1.2 stream-json stdin review rung (#840).
#
# WHY: a review prompt over the agy argv ceiling (534,794 B measured on a real plan) used to be
# refused into the droid rescue, losing the agy lens. agy >=1.2 takes the prompt as one stream-json
# NDJSON message on stdin. These tests pin, with self-contained fake agy binaries (no network, no real
# agy): the rung selection (>=1.2 only, never from inside the reviewed checkout), agy staying the
# trusted argv0, the fresh guard workspace (not the checkout) and its cleanup, byte-exact prompt
# delivery above the argv ceiling, and that error / timeout-partial / empty / denied / truncated
# streams are REJECTED (non-zero, never a review). A complete stream is transport completeness only —
# never a PASS. The PreToolUse guard is best-effort, not enforced containment (known limitation).
set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
LIB="$REPO_ROOT/scripts/lib"
PY=/usr/bin/python3
[[ -x "$PY" ]] || PY=$(command -v python3)
HELPER="$LIB/agy-stream-review.py"

FAILED=0
fail() { echo "FAIL: $*"; FAILED=1; }

# ── helper unit cases (reduce is fed stdout+stderr merged, as the rung captures it) ──────────
_reduce() {  # $1 = stream text (printf %b), $2 = rc; echoes "<exit>"
    printf '%b' "$1" | "$PY" -I "$HELPER" reduce "$2" >/dev/null 2>&1
    printf '%s' "$?"
}
OK_RESULT='{"event":"result","result":{"status":"SUCCESS","response":"REVIEW_OK","num_turns":1}}'
INIT='{"event":"init","init":{"permission_mode":"always-proceed"}}'

[[ "$(_reduce "$INIT\n$OK_RESULT\n" 0)" == 0 ]] || fail "u1: complete SUCCESS stream must be accepted"
got=$(printf '%s\n%s\n' "$INIT" "$OK_RESULT" | "$PY" -I "$HELPER" reduce 0)
[[ "$got" == "REVIEW_OK" ]] || fail "u2: accepted stream must print exactly the response, got [$got]"
[[ "$(_reduce "$INIT\n$OK_RESULT\n" 124)" == 124 ]] || fail "u3: agy timeout rc 124 must be kept"
[[ "$(_reduce "$INIT\n$OK_RESULT\nwarning: print timeout reached, returning partial output\n" 0)" != 0 ]] \
    || fail "u4: exit 0 + stderr warning (timeout partial) must be rejected"
[[ "$(_reduce "$INIT\n" 0)" != 0 ]] || fail "u5: truncated stream (no result) must be rejected"
[[ "$(_reduce "" 0)" != 0 ]] || fail "u6: empty stream must be rejected"
[[ "$(_reduce "$INIT\n"'{"event":"result","result":{"status":"ERROR","error":"boom","num_turns":0}}'"\n" 0)" != 0 ]] \
    || fail "u7: ERROR result must be rejected even with rc 0"
[[ "$(_reduce "$INIT\n"'{"event":"result","result":{"status":"SUCCESS","response":"","num_turns":1,"denied_actions":[{"action":"write_file"}]}}'"\n" 0)" != 0 ]] \
    || fail "u8: headless-denied result (SUCCESS, empty response, denied_actions) must be rejected"
[[ "$(_reduce "$INIT\n"'{"event":"result","result":{"status":"SUCCESS","response":"verdict","num_turns":1,"denied_actions":[{"action":"write_file"}]}}'"\n" 0)" != 0 ]] \
    || fail "u9: a non-empty response with denied_actions must still be rejected"
[[ "$(_reduce "$INIT\n$OK_RESULT\n"'{"event":"step_update","step_update":{}}'"\n" 0)" != 0 ]] \
    || fail "u10: an event after the result must be rejected"
[[ "$(_reduce "$INIT\n"'{"event":"result","result":{"status":"SUCCESS","response":"x","num_turns":true}}'"\n" 0)" != 0 ]] \
    || fail "u11: boolean num_turns must be rejected"
# u13: raw (unescaped) U+2028/U+2029 inside a JSON string must not split the event.
"$PY" -I -c 'import sys; sys.stdout.buffer.write(b"{\"event\":\"result\",\"result\":{\"status\":\"SUCCESS\",\"response\":\"a\xe2\x80\xa8b\xe2\x80\xa9c\",\"num_turns\":1}}\n")' \
    | "$PY" -I "$HELPER" reduce 0 \
    | "$PY" -I -c 'import sys; sys.exit(sys.stdin.buffer.read() != b"a\xe2\x80\xa8b\xe2\x80\xa9c")' \
    || fail "u13: raw U+2028/U+2029 inside a JSON string must not split the event"
# u14: the rejection reason must precede the raw tail (one byte stream, no text-wrapper buffering).
got=$(printf '%s\n' "$INIT" | "$PY" -I "$HELPER" reduce 0 | head -n 1)
[[ "$got" == "agy stream review rejected:"* ]] || fail "u14: rejection reason must be the first output line, got [$got]"
# u15: the guard hook must run isolated (-I) so user site-packages cannot run code before it.
grep -q '"/usr/bin/python3 -I ./guard.py"' "$LIB/agy-review-guard/hooks.json" \
    || fail "u15: guard hook command must be /usr/bin/python3 -I ./guard.py"
printf '\377\376 not utf8' | "$PY" -I "$HELPER" encode >/dev/null 2>&1 \
    && fail "u12: invalid UTF-8 prompt must be refused, not replaced"

# ── guard: a decision is always printed (agy treats an empty hook reply as allow) ─────────────
GUARD_DIR=$(mktemp -d)
cp "$LIB/agy-review-guard/guard.py" "$GUARD_DIR/"
mkdir "$GUARD_DIR/guard.log"   # the audit log cannot be opened → must not suppress the decision
_guard() { printf '%s' "$1" | "$PY" -I "$GUARD_DIR/guard.py" 2>/dev/null; }
[[ "$(_guard '{"toolCall":{"name":"write_file"}}')" == *'"decision": "deny"'* ]] || fail "g1: write_file must be denied even when the log cannot be written"
[[ "$(_guard '{"toolCall":{"name":"view_file"}}')" == *'"decision": "allow"'* ]] || fail "g2: view_file must be allowed"
for bad in 'not json' '[1]' '{"toolCall":"x"}' '{"toolCall":{"name":["view_file"]}}'; do
    [[ "$(_guard "$bad")" == *'"decision": "deny"'* ]] || fail "g3: malformed input [$bad] must be denied, not crash"
done
rm -rf "$GUARD_DIR"

# ── end-to-end through execute_review with fake agy binaries ─────────────────────────────────
# Each fake is baked per scenario (the --review dispatch scrubs the environment, so no FAKE_* vars).
_make_fake() {  # $1 dir, $2 version, $3 scenario; records argv, cwd, guard presence and stdin in $1/log
    mkdir -p "$1/log"
    cat > "$1/agy" <<STUB
#!/bin/sh
if [ "\$1" = "--version" ]; then printf '%s\n' "$2"; exit 0; fi
printf '%s\n' "\$*" > "$1/log/argv"
pwd -P > "$1/log/cwd"
if [ -f .agents/hooks.json ] && [ -f .agents/guard.py ]; then echo yes > "$1/log/guard"; fi
case " \$* " in
  *" --print "*) printf 'ARGV_MODE\n'; exit 0 ;;
esac
cat > "$1/log/stdin"
INIT='$INIT'
case "$3" in
  ok) printf '%s\n%s\n' "\$INIT" '$OK_RESULT' ;;
  warn) printf '%s\n%s\n' "\$INIT" '$OK_RESULT'; printf 'warning: print timeout reached, returning partial output\n' >&2 ;;
  denied) printf '%s\n%s\n' "\$INIT" '{"event":"result","result":{"status":"SUCCESS","response":"","num_turns":1,"denied_actions":[{"action":"write_file"}]}}' ;;
  error) printf '%s\n%s\n' "\$INIT" '{"event":"result","result":{"status":"ERROR","error":"stream input rejected","num_turns":0}}'; exit 1 ;;
  truncated) printf '%s\n' "\$INIT" ;;
  transient) printf '%s\n%s\n' "\$INIT" '{"event":"result","result":{"status":"SUCCESS","response":"Error: 429 Too Many Requests - rate limit exceeded","num_turns":1}}' ;;
esac
STUB
    chmod +x "$1/agy"
}

# $1 version, $2 scenario, $3 prompt bytes, $4 cwd mode (outside|checkout); sets E2E_RC E2E_OUT E2E_DIR
_e2e() {
    E2E_DIR=$(mktemp -d)
    _make_fake "$E2E_DIR" "$1" "$2"
    mkdir -p "$E2E_DIR/cwd"
    # A real checkout, stub outside it: the condition every review runs under (#789 trusted-CLI checks).
    git -C "$E2E_DIR/cwd" init -q >/dev/null 2>&1 || fail "git init failed for the e2e cwd"
    local run_cwd="$E2E_DIR/cwd"
    [[ "$4" == checkout ]] && run_cwd="$REPO_ROOT"
    E2E_OUT=$(cd "$run_cwd" && PATH="$E2E_DIR:$PATH" BUSDRIVER_CLI_RETRIES=0 PROMPT_BYTES="$3" OUTFILE="$E2E_DIR/prompt" bash -c '
        set -uo pipefail
        . "'"$LIB"'/resolve-cli.sh" 2>/dev/null
        # Multibyte, quotes, backslashes and newlines, then ASCII padding to the requested size.
        p=$(printf "é\"\\\\\n\t審查 %.0s" 1 2 3 4 5 6 7 8 9 10)
        pad=$(( PROMPT_BYTES - $(printf "%s" "$p" | wc -c) ))
        p="$p$(head -c "$pad" /dev/zero | tr "\0" "a")"
        printf "%s" "$p" > "$OUTFILE"
        execute_review agy "$p" 30 2>/dev/null')
    E2E_RC=$?
}

# e1: 1.2.x from outside the checkout, prompt ABOVE the argv ceiling → stream rung, exact bytes.
_e2e 1.2.2 ok 600000 outside
[[ "$E2E_RC" == 0 ]] || fail "e1: stream rung rc=$E2E_RC out=[${E2E_OUT:0:200}]"
[[ "$E2E_OUT" == "REVIEW_OK" ]] || fail "e1: expected exactly the response, got [${E2E_OUT:0:200}]"
argv=$(cat "$E2E_DIR/log/argv" 2>/dev/null)
for flag in "--input-format stream-json" "--output-format stream-json" "--mode plan" "--sandbox" "--print-timeout 30s"; do
    [[ "$argv" == *"$flag"* ]] || fail "e1: agy argv lacks [$flag]: [$argv]"
done
[[ "$argv" != *"--print "* && "$argv" != *"--dangerously-skip-permissions"* ]] || fail "e1: unexpected argv [$argv]"
ws=$(printf '%s' "$argv" | sed -n 's/.*--add-dir \([^ ]*\).*/\1/p')
[[ "$ws" == /tmp/agy-review-guard.* ]] || fail "e1: --add-dir must be the fresh guard workspace, got [$ws]"
[[ "$(cat "$E2E_DIR/log/cwd" 2>/dev/null)" == "$(cd /tmp && pwd -P)/${ws#/tmp/}" ]] || fail "e1: agy cwd must be the guard workspace"
[[ "$(cat "$E2E_DIR/log/guard" 2>/dev/null)" == yes ]] || fail "e1: guard hooks.json/guard.py not staged in the workspace"
[[ ! -e "$ws" ]] || fail "e1: guard workspace $ws was not removed"
"$PY" -I - "$E2E_DIR/log/stdin" "$E2E_DIR/prompt" <<'PYCHK' || fail "e1: stdin was not one NDJSON user message carrying the exact prompt bytes"
import json, sys
raw = open(sys.argv[1], "rb").read()
want = open(sys.argv[2], "rb").read()
assert len(want) == 600000, len(want)
assert raw.endswith(b"\n") and raw.count(b"\n") == 1, "not exactly one NDJSON line"
msg = json.loads(raw)
assert msg["event"] == "user" and "role" not in msg["message"]
assert msg["message"]["content"][0]["text"].encode("utf-8") == want
PYCHK
rm -rf "$E2E_DIR"

# e2-e5: rejected streams → non-zero, no response text as a review, workspace still cleaned up.
for scen in warn denied error truncated transient; do
    _e2e 1.2.2 "$scen" 2000 outside
    [[ "$E2E_RC" != 0 ]] || fail "e-$scen: rejected stream returned rc 0 [${E2E_OUT:0:200}]"
    [[ "$E2E_OUT" == *"agy stream review rejected"* ]] || fail "e-$scen: expected a rejection reason, got [${E2E_OUT:0:200}]"
    ws=$(sed -n 's/.*--add-dir \([^ ]*\).*/\1/p' "$E2E_DIR/log/argv" 2>/dev/null)
    [[ -n "$ws" && ! -e "$ws" ]] || fail "e-$scen: guard workspace [$ws] not removed"
    rm -rf "$E2E_DIR"
done

# e6: 1.1.x keeps the argv rung unchanged.
_e2e 1.1.4 ok 2000 outside
[[ "$E2E_RC" == 0 && "$E2E_OUT" == "ARGV_MODE" ]] || fail "e6: agy 1.1.4 must keep the argv rung, rc=$E2E_RC out=[$E2E_OUT]"
rm -rf "$E2E_DIR"

# e7: from INSIDE the reviewed checkout the lib (and its guard) is checkout-controlled → no stream rung.
_e2e 1.2.2 ok 2000 checkout
[[ "$E2E_OUT" == "ARGV_MODE" ]] || fail "e7: stream rung must not use a helper inside the reviewed checkout, out=[$E2E_OUT]"
rm -rf "$E2E_DIR"

if [[ "$FAILED" -eq 0 ]]; then echo "PASS: test-agy-stream-transport"; else exit 1; fi
