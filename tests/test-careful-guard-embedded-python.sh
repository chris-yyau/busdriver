#!/usr/bin/env bash
# test-careful-guard-embedded-python.sh
# The python scanners inside careful-guard.sh must actually COMPILE.
#
# They are embedded in bash SINGLE-quoted strings, so one apostrophe anywhere —
# including in a comment or a docstring — ends the string early. The remainder is
# then handed to bash instead of python. `bash -n` still passes, the scanner dies
# at runtime, its stderr is swallowed by `2>/dev/null`, and the guard silently
# falls back to its degraded grep path: every safe-artifact carve-out disappears
# and the guard warns on everything.
#
# That failure has happened twice. A comment saying "no apostrophes" did not
# prevent the second time, so this asserts it mechanically instead.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GUARD="hooks/gate-scripts/careful-guard.sh"

pass=0 fail=0

# Extract every `python3 ... -c '<block>'` payload and compile it. The extractor
# runs on its own line so its exit status is checked: a crash there would
# otherwise read as "no findings", which is a false PASS.
extract_out=$(python3 - "$GUARD" <<'PY'
import re, sys

src = open(sys.argv[1]).read()
# Each embedded block opens at `python3 <flags> -c '` and runs to the line that
# closes it: a lone `'` starting a line, optionally followed by shell text.
blocks = re.findall(r"python3(?:\s+-\w+)*\s+-c\s+'\n(.*?)\n'", src, re.S)
if not blocks:
    print("FAIL no embedded python block found - has the quoting style changed?")
    raise SystemExit(1)

for i, block in enumerate(blocks, 1):
    if "'" in block:
        # Balanced pairs survive (bash just concatenates), but the text between
        # them reaches BASH rather than python, so report the position.
        line = block[:block.index("'")].count("\n") + 1
        print(f"FAIL block {i} contains an apostrophe at block-line {line}")
        continue
    try:
        compile(block, f"<embedded block {i}>", "exec")
    except SyntaxError as e:
        print(f"FAIL block {i} does not compile: {e.msg} (line {e.lineno})")
        continue
    print(f"PASS block {i} compiles and is apostrophe-free")
PY
) || { echo "FAIL extractor crashed"; echo; echo "passed=0 failed=1"; exit 1; }
mapfile -t results <<<"$extract_out"

for line in "${results[@]}"; do
  echo "$line"
  [[ "$line" == PASS* ]] && pass=$((pass+1)) || fail=$((fail+1))
done

# The degraded path is invisible from the outside, so also assert the scanner
# actually RAN: only the real scanner clears a safe artifact.
payload=$(python3 -c '
import json
print(json.dumps({"permission_mode": "bypassPermissions", "tool_name": "Bash",
                  "tool_input": {"command": "rm -rf node_modules"}}))')
if [[ -z "$payload" ]]; then
  echo "FAIL could not build the guard payload"
  fail=$((fail+1))
  echo
  echo "passed=$pass failed=$fail"
  exit 1
fi
# Check the exit status AND require the allow shape explicitly. This script does
# not run under `set -e`, so a guard that died before printing anything would
# leave guard_out empty — which matches no "ask" and would report a clean PASS,
# the very false-PASS this file exists to prevent.
guard_out=$("$GUARD" <<<"$payload"); guard_rc=$?
if [[ $guard_rc -ne 0 ]]; then
  echo "FAIL guard exited $guard_rc"
  fail=$((fail+1))
elif [[ "$guard_out" == *'"permissionDecision":"ask"'* ]]; then
  echo "FAIL scanner did not run — safe artifact warned (degraded grep path)"
  fail=$((fail+1))
elif [[ "$guard_out" != "{}" ]]; then
  echo "FAIL unexpected guard output: ${guard_out:-<empty>}"
  fail=$((fail+1))
else
  echo "PASS scanner ran — safe artifact cleared"
  pass=$((pass+1))
fi

# Compilation is not execution: a NameError on a branch only some commands
# reach dies at RUNTIME, its stderr is swallowed, and the guard degrades to the
# grep path — which warns, so a test asserting "ask" would still pass. This
# command is one the degraded path WARNS on (it contains the word) and the real
# scanner CLEARS, so it can only pass when the find branch actually executed.
payload=$(python3 -c '
import json
print(json.dumps({"permission_mode": "bypassPermissions", "tool_name": "Bash",
                  "tool_input": {"command": "find . -name \"truncate.log\" -exec ls {} ;"}}))')
if [[ -z "$payload" ]]; then
  echo "FAIL could not build the guard payload for the find branch"
  fail=$((fail+1))
  echo
  echo "passed=$pass failed=$fail"
  exit 1
fi
guard_out=$("$GUARD" <<<"$payload"); guard_rc=$?
if [[ $guard_rc -ne 0 ]]; then
  echo "FAIL guard exited $guard_rc on the find branch"
  fail=$((fail+1))
elif [[ "$guard_out" != "{}" ]]; then
  echo "FAIL find branch degraded to grep: ${guard_out:-<empty>}"
  fail=$((fail+1))
else
  echo "PASS find branch executed without dying"
  pass=$((pass+1))
fi

# The inner SIGALRM must leave headroom under the OUTER hook timeout, or the
# scanner never gets to print the conservative verdict it arms the alarm for:
# the outer timer starts earlier (command extraction, two Python startups) and
# kills the hook with NO decision, which the harness reads as allow. Both were
# 3s, so the outer always won. A comment cannot hold this - the two numbers sit
# in different files and only this assertion couples them.
inner=$(grep -oE 'signal\.alarm\([0-9]+\)' "$GUARD" | grep -oE '[0-9]+' | head -1)
outer=$(python3 - hooks/hooks.json <<'PY'
import json, sys
for event in json.load(open(sys.argv[1])).get("hooks", {}).values():
    for group in event:
        for h in group.get("hooks", []):
            if "careful-guard.sh" in h.get("command", ""):
                print(h.get("timeout", "")); raise SystemExit
PY
)
if [[ -z "$inner" || -z "$outer" ]]; then
  echo "FAIL could not read the timeouts (inner=${inner:-<none>} outer=${outer:-<none>})"
  fail=$((fail+1))
elif (( outer <= inner )); then
  echo "FAIL hook timeout ${outer}s does not clear the ${inner}s scan alarm — the conservative verdict cannot be printed"
  fail=$((fail+1))
elif (( outer - inner < 2 )); then
  echo "FAIL only $((outer-inner))s between the ${inner}s alarm and the ${outer}s hook timeout — too tight for startup"
  fail=$((fail+1))
else
  echo "PASS scan alarm ${inner}s clears the ${outer}s hook timeout"
  pass=$((pass+1))
fi

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
