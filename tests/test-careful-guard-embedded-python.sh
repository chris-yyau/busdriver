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

# Extract every `python3 ... -c '<block>'` payload and compile it.
mapfile -t results < <(python3 - "$GUARD" <<'PY'
import re, sys

src = open(sys.argv[1]).read()
# Each embedded block opens at `python3 <flags> -c '` and runs to the line that
# closes it: a lone `'` starting a line, optionally followed by shell text.
blocks = re.findall(r"python3(?:\s+-\w+)*\s+-c\s+'\n(.*?)\n'", src, re.S)
if not blocks:
    print("FAIL no embedded python block found - has the quoting style changed?")
    raise SystemExit

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
)

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
if [[ "$("$GUARD" <<<"$payload")" == *'"permissionDecision":"ask"'* ]]; then
  echo "FAIL scanner did not run — safe artifact warned (degraded grep path)"
  fail=$((fail+1))
else
  echo "PASS scanner ran — safe artifact cleared"
  pass=$((pass+1))
fi

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
