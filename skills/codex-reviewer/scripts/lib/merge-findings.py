#!/usr/bin/env python3
"""Merge findings from SAST, markdown checker, and LLM review.

Reads JSON arrays from stdin (one per line) or as arguments.
Deduplicates by file + line + description similarity.
Outputs merged JSON with proper status determination.

Usage:
  printf '%s\\n%s\\n' '[]' '[]' | python3 merge-findings.py
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

    SAST/lint findings (source starts with 'sast:' or 'lint:') always block.
    LLM findings block if confidence >= 0.5 (confidence may be 0-1 float
    or 0-100 integer — normalize to 0-1 range).
    """
    for f in findings:
        if f.get("severity") not in ("high", "medium"):
            continue
        source = f.get("source", "")
        if source.startswith("sast:") or source.startswith("lint:"):
            return "FAIL"
        # Normalize confidence: accept both 0-1 and 0-100 scales
        confidence = f.get("confidence")
        if confidence is None:
            # No confidence field = deterministic source, always block
            return "FAIL"
        try:
            confidence = float(confidence)
        except (TypeError, ValueError):
            return "FAIL"
        # Normalize 0-100 to 0-1
        if confidence > 1.0:
            confidence = confidence / 100.0
        if confidence >= 0.5:
            return "FAIL"
    return "PASS"


def main() -> None:
    all_findings: list[dict] = []
    parse_errors = 0
    total_inputs = 0

    if len(sys.argv) > 1:
        for arg in sys.argv[1:]:
            total_inputs += 1
            try:
                parsed = json.loads(arg)
                if isinstance(parsed, list):
                    all_findings.extend(parsed)
                elif isinstance(parsed, dict) and "issues" in parsed:
                    all_findings.extend(parsed["issues"])
            except (json.JSONDecodeError, ValueError):
                parse_errors += 1
                continue
    else:
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            total_inputs += 1
            try:
                parsed = json.loads(line)
                if isinstance(parsed, list):
                    all_findings.extend(parsed)
                elif isinstance(parsed, dict) and "issues" in parsed:
                    all_findings.extend(parsed["issues"])
            except (json.JSONDecodeError, ValueError):
                parse_errors += 1
                continue

    # If ALL inputs failed to parse, fail-closed (not silent PASS)
    if total_inputs > 0 and parse_errors == total_inputs:
        result = {
            "status": "FAIL",
            "issues": [{
                "file": "",
                "line": 0,
                "severity": "high",
                "category": "internal",
                "description": f"[merge-findings] All {total_inputs} input(s) failed JSON parsing — fail-closed",
                "suggestion": "Check upstream tool output for errors",
                "source": "internal:merge-findings"
            }]
        }
        print(json.dumps(result))
        return

    deduped = deduplicate(all_findings)
    status = determine_status(deduped)

    result = {"status": status, "issues": deduped}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
