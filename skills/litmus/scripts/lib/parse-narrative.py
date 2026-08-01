#!/usr/bin/env python3
"""
Parse codex narrative output and convert to JSON format.
Handles reasoning mode output where codex provides detailed feedback
instead of pure JSON.
"""

import sys
import json
import re

def parse_narrative_to_json(text):
    """
    Convert codex narrative review output to JSON format.

    Looks for patterns like:
    - [P0]/[P1]/[P2] for severity (P0=high, P1=high, P2=medium)
    - File paths and line numbers
    - Issue descriptions
    """

    # Look for codex's actual response (after "codex" label)
    if "codex" in text.lower():
        start_pos = text.lower().rfind("codex")
        newline_pos = text.find("\n", start_pos)
        if newline_pos != -1:
            text = text[newline_pos + 1:]

    issues = []

    # Pattern for codex P-level issues:
    # - [P0] Description — file:line
    # - [P1] Description — file:line
    # - [P2] Description — file:line
    pattern = r'-\s*\[(P[0-2])\]\s*([^—]+)\s*—\s*([^:]+):(\d+)(?:-(\d+))?'

    for match in re.finditer(pattern, text, re.MULTILINE):
        p_level = match.group(1)
        description = match.group(2).strip()
        file_path = match.group(3).strip()
        line_start = int(match.group(4))

        # Map P-levels to severity
        severity_map = {
            'P0': 'high',
            'P1': 'high',
            'P2': 'medium'
        }
        severity = severity_map.get(p_level, 'medium')

        # Determine category from keywords
        desc_lower = description.lower()
        if any(word in desc_lower for word in ['security', 'injection', 'xss', 'eval', 'exec', 'vulnerability']):
            category = 'security'
        elif any(word in desc_lower for word in ['performance', 'slow', 'memory', 'leak']):
            category = 'performance'
        elif any(word in desc_lower for word in ['bug', 'error', 'null', 'undefined', 'race']):
            category = 'bug'
        else:
            category = 'maintainability'

        # Look for suggestion in following text
        # Usually appears as indented text after the issue line
        suggestion = "Review and fix according to best practices"

        issues.append({
            "file": file_path,
            "line": line_start,
            "severity": severity,
            "category": category,
            "description": description,
            "suggestion": suggestion
        })

    # Nothing matched: return no verdict at all.
    #
    # This branch used to return {"status": "PASS", "issues": []}, and the loop wrote
    # litmus-passed.local on the strength of it. That is a fail-OPEN: this parser only
    # runs AFTER structured extraction has already failed, so "I matched no findings"
    # means the reviewer output was unreadable -- never that the code is clean. Prose
    # explicitly reporting a critical bug, a truncated FAIL verdict, and a Python
    # traceback all landed here and all came back PASS.
    #
    # Note the PASS branch below was ONLY ever reachable from here: the pattern matches
    # P0/P1/P2 only, which map to high/high/medium, so any parsed issue makes
    # has_high_medium true. Approving on silence was the sole behaviour it had.
    if not issues:
        return None

    # Kept rather than hardcoding FAIL: if the severity map ever gains a low tier, an
    # all-low narrative IS a genuine pass -- the parser understood the output and found
    # nothing blocking. That is a different claim from having understood nothing.
    has_high_medium = any(issue['severity'] in ['high', 'medium'] for issue in issues)
    status = "FAIL" if has_high_medium else "PASS"

    return {
        "status": status,
        "issues": issues
    }

if __name__ == "__main__":
    text = sys.stdin.read()
    result = parse_narrative_to_json(text)
    if result is None:
        # Non-zero exit routes run-review-loop.sh into its existing infra_failure path
        # (the `PARSE_EXIT -ne 0` branch), which reports and stops rather than deciding.
        # An unreadable review is a review that did not happen, not a review that passed.
        sys.stderr.write(
            "parse-narrative: no findings matched the expected format; "
            "refusing to emit a verdict for an unreadable review\n"
        )
        sys.exit(2)
    print(json.dumps(result))
