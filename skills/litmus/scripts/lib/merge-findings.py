#!/usr/bin/env python3
"""Merge findings from SAST, markdown checker, and LLM review.

Reads concatenated JSON values from stdin (single-line or pretty-printed)
or as command-line arguments.
Deduplicates by file + line + description similarity.
Outputs merged JSON with proper status determination.

Usage:
  printf '%s\\n%s\\n' '[]' '[]' | python3 merge-findings.py
  python3 merge-findings.py '[ ... ]' '[ ... ]'
"""

import json
import os
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


def _is_deterministic_blocker(finding: dict) -> bool:
    """Check if a finding is from a deterministic source (SAST/lint) at blocking severity."""
    severity = finding.get("severity", "")
    source = finding.get("source", "")
    return severity in ("high", "medium") and (source.startswith("sast:") or source.startswith("lint:"))


def determine_status(findings: list[dict]) -> str:
    """FAIL if any blocking finding exists.

    Blocking rules:
    - SAST/lint findings (source starts with 'sast:' or 'lint:') always block.
    - LLM findings block if confidence >= 70% (normalized).
    - After iteration 2 (env LITMUS_ITERATION >= 3), only HIGH LLM findings block.
      MEDIUM LLM findings become advisory (still reported, not blocking).
      Note: this is a server-side override of the prompt contract, which tells
      the LLM to FAIL on any medium. The LLM still reports them; the gate relaxes.
    """
    try:
        iteration = int(os.environ.get("LITMUS_ITERATION", "1"))
    except (TypeError, ValueError):
        iteration = 1
    blocking_severities = {"high", "medium"} if iteration <= 2 else {"high"}

    for f in findings:
        if _is_deterministic_blocker(f):
            return "FAIL"
        if f.get("severity", "") not in blocking_severities:
            continue
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
        if confidence >= 0.7:
            return "FAIL"
    return "PASS"


def _ingest(parsed: object, sink: list[dict]) -> None:
    """Pull issues out of a parsed JSON value into the findings sink."""
    if isinstance(parsed, list):
        sink.extend(parsed)
    elif isinstance(parsed, dict) and "issues" in parsed:
        sink.extend(parsed["issues"])


def _parse_concatenated_json(text: str) -> tuple[list[object], int]:
    """Parse whitespace-separated JSON values from a single text buffer.

    Returns (parsed_values, parse_errors). Handles both single-line-per-value
    input (the historical contract from `printf '%s\\n%s\\n%s\\n' ...`) AND
    pretty-printed multi-line JSON (which the extractor at
    skills/blueprint-review/scripts/lib/extract_review_json.py always emits
    via `json.dumps(result, indent=2)`). Without this, multi-line LLM
    verdicts silently get dropped from the merge — exactly the failure mode
    that left litmus relying solely on SAST in production until
    issue #105's fixture exposed it.
    """
    def _is_json_restart(ch: str) -> bool:
        """Return True when ch could start a valid JSON value.

        Restart characters: whitespace (objects/arrays/strings/numbers skip
        leading whitespace), `{`/`[`/`"` (object/array/string), `-` or digit
        (number), and `t`/`f`/`n` (true/false/null literals).
        """
        return ch.isspace() or ch in ('{', '[', '"', '-', 't', 'f', 'n') or ch.isdigit()

    decoder = json.JSONDecoder()
    parsed_values: list[object] = []
    parse_errors = 0
    i = 0
    n = len(text)
    while i < n:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            break
        try:
            obj, i = decoder.raw_decode(text, i)
            parsed_values.append(obj)
        except json.JSONDecodeError:
            parse_errors += 1
            # Advance past the current malformed token to the next position
            # where a valid JSON value could plausibly begin (after whitespace,
            # at a `{`, `[`, `"`, `-`, digit, or JSON literal start `t`/`f`/`n`).
            # The previous first-whitespace stop left embedded-space garbage
            # (e.g. `{"bad": content}`) to be retried word-by-word, inflating
            # parse_errors and the total_inputs diagnostic counter.
            # Fail-closed and valid-JSON-preservation behaviors are unchanged.
            i += 1  # guarantee progress past the current char
            while i < n and not _is_json_restart(text[i]):
                i += 1
    return parsed_values, parse_errors


def main() -> None:
    all_findings: list[dict] = []
    parse_errors = 0
    total_inputs = 0

    if len(sys.argv) > 1:
        for arg in sys.argv[1:]:
            total_inputs += 1
            try:
                _ingest(json.loads(arg), all_findings)
            except (json.JSONDecodeError, ValueError):
                parse_errors += 1
                continue
    else:
        text = sys.stdin.read()
        parsed_values, parse_errors = _parse_concatenated_json(text)
        for obj in parsed_values:
            _ingest(obj, all_findings)
        total_inputs = len(parsed_values) + parse_errors

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
