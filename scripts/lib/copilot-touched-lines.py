#!/usr/bin/env python3
"""scripts/lib/copilot-touched-lines.py

Reads `git diff <base>..HEAD -U0` on stdin; emits a JSON array of
{path, start, end} objects describing line ranges added/modified in HEAD.

Uses the `+++ b/<path>` header (NOT `diff --git a/<path>`) so renames and
paths-with-spaces resolve to the post-rename file. Stdlib-only. POSIX
Python 3. Tested under macOS default Python 3 / BSD environment.
"""
import json
import re
import sys

_NEW_PATH = re.compile(r"^\+\+\+ b/(.+)$")
_HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def parse(lines):
    result = []
    current = None
    for raw in lines:
        line = raw.rstrip("\n")
        m = _NEW_PATH.match(line)
        if m:
            current = m.group(1)
            continue
        m = _HUNK.match(line)
        if m and current:
            start = int(m.group(1))
            length = int(m.group(2)) if m.group(2) else 1
            if length <= 0:
                continue
            result.append({
                "path": current,
                "start": start,
                "end": start + length - 1,
            })
    return result


if __name__ == "__main__":
    print(json.dumps(parse(sys.stdin), separators=(",", ":")))
