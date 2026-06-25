#!/usr/bin/env python3
"""Regression tests for the heuristic agent self-evaluator.

These cases lock in PR #240 review findings from Codex/Devin/CodeRabbit so the
regex-heavy scoring logic does not regress after the grind converges.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path


_SCRIPT = Path(__file__).with_name("evaluate.py")
_SPEC = importlib.util.spec_from_file_location("agent_self_evaluate", _SCRIPT)
assert _SPEC and _SPEC.loader
_evaluate = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_evaluate)


def evidence_text(score) -> str:
    return "\n".join(score.evidence)


def test_mixed_passed_and_failed_results_cap_accuracy() -> None:
    score = _evaluate.check_accuracy("Ran pytest: 10 passed, 1 failed.")

    assert score.score <= 2
    assert "Failed tests" in evidence_text(score)


def test_uncounted_failed_test_phrases_cap_accuracy_with_evidence() -> None:
    for text in ("Tests did not pass", "pytest failed", "lint failed"):
        score = _evaluate.check_accuracy(text)

        assert score.score <= 2, text
        assert "Failed tests/lint reported" in evidence_text(score), text


def test_zero_failed_counts_do_not_cap_accuracy_as_failures() -> None:
    for text in (
        "No tests failed. 12 passed.",
        "0 tests failed. 12 passed.",
        "Tests failed: 0. 12 passed.",
        "tests failed (0), 12 passed",
        "tests failed: none; 12 passed",
    ):
        score = _evaluate.check_accuracy(text)

        assert score.score > 2, text
        assert "Failed tests" not in evidence_text(score), text


def test_duration_after_tests_failed_is_not_treated_as_zero_count() -> None:
    score = _evaluate.check_accuracy("Tests failed (0.2s).")

    assert score.score <= 2
    assert "Failed tests/lint reported" in evidence_text(score)


def test_markdown_emphasis_does_not_hide_negated_positive_signal() -> None:
    score = _evaluate.check_accuracy("The result was not **verified** with pytest.")

    assert score.score <= 3
    assert "+ Explicit verification" not in evidence_text(score)


def test_absent_coverage_suppresses_positive_and_deducts() -> None:
    for text in (
        "Error handling is absent.",
        "error handling missing",
        "exception handling absent",
        "try/except missing",
    ):
        score = _evaluate.check_completeness(text)

        assert score.score <= 3, text
        assert "Coverage explicitly absent" in evidence_text(score), text
        assert "+ Error handling present" not in evidence_text(score), text


def test_missing_file_phrase_is_not_misread_as_missing_coverage() -> None:
    score = _evaluate.check_completeness(
        "Implemented error handling for missing files and verified that edge cases are covered."
    )

    assert score.score >= 4
    assert "Coverage explicitly absent" not in evidence_text(score)


def test_negated_pr_creation_does_not_count_as_actionable_pr_created() -> None:
    score = _evaluate.check_actionability("PR not created; next steps: fix the tests first.")

    assert "+ PR created" not in evidence_text(score)
