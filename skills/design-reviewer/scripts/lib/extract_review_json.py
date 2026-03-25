#!/usr/bin/env python3
"""Extract review JSON from raw CLI output (Gemini, Codex, etc.).

The raw output from these CLIs often contains:
- Non-JSON preamble (config warnings, session info, loading messages)
- Interleaved exec command outputs with code snippets (unmatched braces!)
- Token usage stats
- The actual review JSON (usually at the end, on one line)

Strategy (ordered by reliability):
1. Parse the whole file as JSON (clean output)
2. Line-scan: find lines containing valid JSON with reviewer_id/issues
3. Reverse brace-matching: scan backwards from end to find the review JSON
4. Forward brace-matching: legacy approach (fails with interleaved code)

Usage:
  python3 extract_review_json.py <raw_file>   # from file
  echo "..." | python3 extract_review_json.py -   # from stdin
Prints extracted JSON to stdout. Exit 0 on success, 1 on failure.
"""

import json
import re
import sys


def try_whole_file(raw: str):
    """Strategy 1: Parse entire file as JSON."""
    try:
        obj = json.loads(raw)
        if "reviewer_id" in obj or "issues" in obj:
            return obj
    except (json.JSONDecodeError, ValueError):
        pass
    return None


def try_line_scan(raw: str):
    """Strategy 2: Find lines containing valid review JSON.

    CLI review output typically puts the review JSON on a single line.
    This handles interleaved exec output with unmatched braces because
    we parse each line independently.
    """
    candidates = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
            if "reviewer_id" in obj or ("status" in obj and "issues" in obj):
                candidates.append(obj)
        except (json.JSONDecodeError, ValueError):
            continue

    if not candidates:
        return None

    # Prefer objects with reviewer_id
    for c in reversed(candidates):  # last one is most likely the final output
        if "reviewer_id" in c:
            return c
    return candidates[-1]


def try_reverse_brace_match(raw: str):
    """Strategy 3: Scan backwards from end to find last complete JSON object.

    Avoids the depth-imbalance problem of forward scanning by starting from
    the end where the review JSON lives.
    """
    # Find the last '}' in the file
    i = len(raw) - 1
    while i >= 0 and raw[i] != "}":
        i -= 1
    if i < 0:
        return None

    # Walk backwards to find matching '{'
    end = i
    depth = 0
    while i >= 0:
        ch = raw[i]
        if ch == "}":
            depth += 1
        elif ch == "{":
            depth -= 1
            if depth == 0:
                try:
                    obj = json.loads(raw[i : end + 1])
                    if "reviewer_id" in obj or ("status" in obj and "issues" in obj):
                        return obj
                except (json.JSONDecodeError, ValueError):
                    pass
                # This wasn't valid JSON, try next outer '}'
                end_search = i - 1
                while end_search >= 0 and raw[end_search] != "}":
                    end_search -= 1
                if end_search < 0:
                    return None
                end = end_search
                i = end_search
                depth = 0
                continue
        i -= 1
    return None


def try_regex_extract(raw: str):
    """Strategy 4: Use regex to find JSON-like blocks with review fields."""
    # Find all occurrences of {"status": followed by content until a matching }
    pattern = r'\{"status"\s*:\s*"(?:PASS|FAIL|ERROR)"[^}]*"issues"\s*:\s*\[.*?\]\s*(?:,\s*"metadata"\s*:\s*\{[^}]*\})?\s*\}'
    matches = re.findall(pattern, raw, re.DOTALL)
    for match in reversed(matches):
        try:
            obj = json.loads(match)
            return obj
        except (json.JSONDecodeError, ValueError):
            continue
    return None


def extract_from_text(raw: str):
    """Try each extraction strategy in order."""
    for strategy in [try_whole_file, try_line_scan, try_reverse_brace_match, try_regex_extract]:
        result = strategy(raw)
        if result:
            return result
    return None


def extract(source: str):
    """Extract from file path or '-' for stdin."""
    if source == "-":
        raw = sys.stdin.read()
    else:
        with open(source) as f:
            raw = f.read()
    return extract_from_text(raw)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: extract_review_json.py <raw_file|->", file=sys.stderr)
        sys.exit(1)

    result = extract(sys.argv[1])
    if result:
        print(json.dumps(result, indent=2))
        sys.exit(0)
    else:
        sys.exit(1)
