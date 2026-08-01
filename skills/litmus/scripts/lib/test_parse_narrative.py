"""Tests for the litmus narrative fallback parser.

This parser runs ONLY after structured JSON extraction has already failed, so every
input it sees is output the reviewer garbled. Its job is to salvage a verdict when it
genuinely can -- and to refuse to invent one when it cannot.

The bug these tests pin (#544): a review it could not read returned
`{"status": "PASS", "issues": []}`, and the loop wrote `litmus-passed.local` on the
strength of it. Observed inverting a real verdict on a byte-identical diff: narrative
said PASS/0, the structured reviewer said FAIL with a high-severity fail-open.
"""

import json
import subprocess
import sys
from pathlib import Path

PARSER = Path(__file__).with_name("parse-narrative.py")


def run(text):
    """Invoke the parser exactly as run-review-loop.sh does. Returns (exit_code, stdout)."""
    p = subprocess.run(
        [sys.executable, str(PARSER)],
        input=text, capture_output=True, text=True,
    )
    return p.returncode, p.stdout


# ── The fail-open, in the two shapes actually observed in the wild ──────────────

def test_prose_describing_a_critical_bug_is_not_a_pass():
    rc, out = run("codex\nI found a critical security bug. Severity: HIGH.\n")
    assert rc != 0, f"prose describing a HIGH bug was accepted as a verdict: {out!r}"


def test_truncated_fail_json_is_not_a_pass():
    rc, out = run('{"status": "FAIL", "issues": [{"severity": "high", "desc')
    assert rc != 0, f"a truncated FAIL verdict was accepted: {out!r}"


def test_empty_input_is_not_a_pass():
    rc, out = run("")
    assert rc != 0, f"empty reviewer output was accepted as a verdict: {out!r}"


def test_silence_is_never_a_pass():
    """The general property, not just the three inputs above.

    PASS was only ever reachable when zero issues matched -- i.e. exactly when the
    parser understood nothing. There is no input for which "I parsed no findings"
    justifies approving a commit.
    """
    for text in [
        "codex\nLooks good to me, no notes.\n",
        "codex\nP0: something is broken but not in the expected shape\n",
        "Traceback (most recent call last):\n  File x\nValueError: boom\n",
        "codex\n- [P9] unknown severity level — file.py:1\n",
    ]:
        rc, out = run(text)
        assert rc != 0, f"unparseable input yielded a verdict: {text!r} -> {out!r}"


# ── The salvage path must still work: a readable FAIL is still a FAIL ───────────

def test_recognised_findings_still_parse_to_fail():
    rc, out = run("codex\n- [P0] SQL injection — db.py:42\n")
    assert rc == 0, "a parseable narrative FAIL should still be reported"
    d = json.loads(out)
    assert d["status"] == "FAIL"
    assert len(d["issues"]) == 1
    assert d["issues"][0]["file"] == "db.py"
    assert d["issues"][0]["line"] == 42
    assert d["issues"][0]["severity"] == "high"


def test_multiple_findings_and_severity_mapping():
    rc, out = run(
        "codex\n"
        "- [P0] Remote code execution — a.py:1\n"
        "- [P1] Auth bypass — b.py:2\n"
        "- [P2] Slow query — c.py:3\n"
    )
    assert rc == 0
    d = json.loads(out)
    assert d["status"] == "FAIL"
    assert [i["severity"] for i in d["issues"]] == ["high", "high", "medium"]


def test_output_is_a_single_json_object_on_the_salvage_path():
    """The loop pipes stdout straight into jq, so stdout must stay clean JSON."""
    rc, out = run("codex\n- [P0] SQL injection — db.py:42\n")
    assert rc == 0
    json.loads(out)  # raises if stdout carries anything but the verdict
