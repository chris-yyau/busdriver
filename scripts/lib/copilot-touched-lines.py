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


def _hunk_range(match, path):
    """Return a {path, start, end} dict for a hunk, or None for zero-length hunks."""
    start = int(match.group(1))
    length = int(match.group(2)) if match.group(2) else 1
    if length <= 0:
        return None
    return {"path": path, "start": start, "end": start + length - 1}


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
        if m and current and (entry := _hunk_range(m, current)) is not None:
            result.append(entry)
    return result


if __name__ == "__main__":
    print(json.dumps(parse(sys.stdin), separators=(",", ":")))
