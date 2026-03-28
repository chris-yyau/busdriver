#!/usr/bin/env python3
"""Merge findings from SAST, markdown checker, and LLM review.

Reads JSON arrays from stdin (one per line) or as arguments.
Deduplicates by file + line + description similarity.
Outputs merged JSON with proper status determination.

Usage:
  printf '%s\n%s\n' '[]' '[]' | python3 merge-findings.py
  python3 merge-findings.py '[ ... ]' '[ ... ]'
"""

import json
import sys
from difflib import SequenceMatcher


def deduplicate(findings: list[dict]) -> list[dict]:
    """Remove duplicate findings based on file + line + description similarity."""
    seen: list[dict] = []
    for f in findings:
        is_dup = False
        for s in seen:
            if (f.get("file") == s.get("file")
                    and abs(f.get("line", 0) - s.get("line", 0)) <= 3):
                sim = SequenceMatcher(
                    None,
                    f.get("description", "").lower(),
                    s.get("description", "").lower(),
                ).ratio()
                if sim > 0.6:
                    is_dup = True
                    sev_rank = {"high": 3, "medium": 2, "low": 1}
                    if sev_rank.get(f.get("severity"), 0) > sev_rank.get(s.get("severity"), 0):
                        seen.remove(s)
                        seen.append(f)
                    break
        if not is_dup:
            seen.append(f)
    return seen


def determine_status(findings: list[dict]) -> str:
    """FAIL if any high/medium severity finding blocks.

    SAST findings (no confidence field or source starts with 'sast:') always block.
    LLM findings with confidence < 0.5 are advisory (don't block).
    """
    for f in findings:
        if f.get("severity") not in ("high", "medium"):
            continue
        source = f.get("source", "")
        if source.startswith("sast:") or source.startswith("lint:"):
            return "FAIL"
        confidence = f.get("confidence", 1.0)
        if confidence >= 0.5:
            return "FAIL"
    return "PASS"


def main():
    all_findings: list[dict] = []

    if len(sys.argv) > 1:
        for arg in sys.argv[1:]:
            try:
                parsed = json.loads(arg)
                if isinstance(parsed, list):
                    all_findings.extend(parsed)
                elif isinstance(parsed, dict) and "issues" in parsed:
                    all_findings.extend(parsed["issues"])
            except (json.JSONDecodeError, ValueError):
                continue
    else:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                parsed = json.loads(line)
                if isinstance(parsed, list):
                    all_findings.extend(parsed)
                elif isinstance(parsed, dict) and "issues" in parsed:
                    all_findings.extend(parsed["issues"])
            except (json.JSONDecodeError, ValueError):
                continue

    deduped = deduplicate(all_findings)
    status = determine_status(deduped)

    result = {"status": status, "issues": deduped}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
