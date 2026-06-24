#!/usr/bin/env python3
"""Standalone agent output evaluator using the 5-axis rubric.

Reads a task description and agent output from stdin or files,
scores each axis, and prints a structured evaluation report.

Usage:
    # Pipe agent output directly via stdin (no task context)
    echo "Agent response here" | evaluate.py

    # From files
    evaluate.py --task task.txt --output response.txt

    # Interactive (reads task from prompt, output from stdin)
    evaluate.py --interactive

The evaluator uses keyword heuristics + structural checks as a first pass.
For production use, pair with an LLM judge for semantic understanding.
"""

import argparse
import re
import sys
from dataclasses import dataclass, field
from typing import Optional

# Tunable thresholds for evaluation heuristics
WALL_OF_TEXT_WORDS = 200
SUMMARY_CHECK_WORDS = 300
SUMMARY_CHECK_FIRST_N = 100
TASK_OUTPUT_RATIO_HIGH = 15
TASK_OUTPUT_RATIO_MEDIUM = 8


@dataclass
class AxisScore:
    name: str
    score: int
    evidence: list[str] = field(default_factory=list)
    improvement: Optional[str] = None


def count_words(text: str) -> int:
    return len(text.split()) if text else 0


# Negation / absence words that, appearing just before a positive signal,
# invert it ("No PR created", "missing error handling", "lacks tests",
# "tests did not pass", "lint is not clean"). Single source of truth so the
# prefix check (_NEGATION) and any interior-negation tempered gaps (e.g. the
# PR-created pattern) stay in sync.
_NEG_WORDS = (
    r"no|not|never|without|missing|lacks?|lacking|absent|"
    r"fail(?:ed|s|ing)?|couldn'?t|can'?t|cannot|"
    r"didn'?t|don'?t|won'?t|isn'?t|aren'?t|wasn'?t|weren'?t"
)
# The character class spans markdown emphasis markers (`*` for **bold**,
# `_` already covered by \w) so negated phrases like "not **verified**" or
# "no _tests passed_" are still detected — without `*` the emphasis asterisks
# break the bounded lookback and the positive signal scores as real evidence.
_NEGATION = re.compile(rf"(?i)\b(?:{_NEG_WORDS})\b[\s\w*'\"`]{{0,15}}$")


def _positive_match(pattern: str, text: str) -> bool:
    """True if `pattern` matches text NOT immediately preceded by a negation.

    Prevents negated phrases from being scored as positive evidence, which
    would defeat the fail-closed scoring (e.g. "No PR created" must not count
    as "+ PR created").
    """
    for m in re.finditer(pattern, text):
        prefix = text[max(0, m.start() - 30):m.start()]
        if _NEGATION.search(prefix):
            continue
        return True
    return False


# Shared coverage vocabulary, reused by the positive matcher and the gap signal
# so the two stay symmetric: every absence phrase that suppresses a positive
# also lands a deduction (no suppress-without-deduct asymmetry).
# Error-handling alternation defined once and shared by the positive signal and
# the gap nouns, so _coverage_match suppression and the deduction stay symmetric
# (the try/except shorthands must be deductible, not just suppressible).
_ERR_HANDLING = r"\berror\s*handling\b|\bexception\s*handling\b|\btry/except\b|\btry\s*\{"
# Per-alternative \b boundaries (not an outer wrap) so try/except and "try {"
# work while \btests?\b still won't match inside "latest"/"contest".
_COVERAGE_NOUNS = rf"{_ERR_HANDLING}|\bedge\s*cases?\b|\bvalidation\b|\btests?\b"
# A coverage noun reads as "absent" when an absence indicator follows it through
# a COPULA/auxiliary connector only (is/are/was/were/has·have·had·been, or a
# colon) — never a preposition. That restriction is what keeps "error handling
# for missing files" (coverage CLAIMED for missing-file inputs) from being read
# as an admission that error handling is missing.
_LINK = r"(?:\s*:\s*|(?:\s+(?:is|are|was|were|has|have|had|been)\b)+\s+)"
# Absence indicators: bare adjectives (always absence) OR a negated state. The
# negation lives in the indicator, not the connector, so "is implemented" stays
# a positive while "is not/never [been] implemented" is an absence.
# `none` is gated so a bare "none" inside a larger phrase ("Tests: none
# failed.") is NOT read as absence — only "none" at the end of a clause
# (end-of-string or before punctuation) OR "none" followed by an
# absence-completing participle ("none implemented", "none present") is.
# Prevents false deductions where "none" modifies a following positive
# ("none failed") while still catching "none implemented" / "none present".
_ABS_BARE = (
    r"absent|missing|lacking|omitted|"
    r"none(?=\s*(?:$|[.,;:!?]|(?:implemented|present|covered|handled|"
    r"addressed|included|done|provided|available|written|added|created|"
    r"performed|exercised|tested|run|checked|reviewed|verified|completed)\b))|"
    r"nonexistent|unhandled|unimplemented|uncovered"
)
_NEG_SUPPRESS = r"(?:not|never)\s+(?:been\s+)?(?:present|handled|implemented|included|done|covered|addressed)"
# Gap-deduction set omits the bare "not covered"/"not handled" forms — the
# generic "Explicit gap acknowledged" pattern already deducts those, so omitting
# them here prevents one admission counting as two gaps. It still keeps the
# "not/never been covered/handled" and "never covered/handled" forms, which that
# generic pattern does NOT match.
_NEG_GAP = (
    r"(?:not|never)\s+(?:present|implemented|included|done|addressed)"
    r"|(?:not|never)\s+been\s+(?:present|handled|implemented|included|done|covered|addressed)"
    r"|never\s+(?:covered|handled)"
)
# Absence indicator immediately AFTER a coverage signal inverts it ("error
# handling is absent", "edge cases: none", "tests have not been done").
# Complements _NEGATION (which catches absence words only BEFORE the signal).
# Fail-closed: a contrived double negative ("is not absent") is under-credited,
# the safe direction for this evaluator.
_ABSENCE_SUFFIX = re.compile(rf"(?i)^{_LINK}(?:{_ABS_BARE}|{_NEG_SUPPRESS})\b")


def _coverage_match(pattern: str, text: str) -> bool:
    """Positive coverage match that rejects a hit negated BEFORE (_NEGATION) or
    immediately AFTER (_ABSENCE_SUFFIX) the signal, so an explicit admission such
    as "error handling is absent" is not scored as "+ ... present". The suffix
    search runs against the full remainder (the ^-anchored, length-bounded regex
    self-limits) so a longer phrase like "not covered" is never truncated."""
    for m in re.finditer(pattern, text):
        prefix = text[max(0, m.start() - 30):m.start()]
        if _NEGATION.search(prefix):
            continue
        if _ABSENCE_SUFFIX.search(text[m.end():]):
            continue
        return True
    return False


def _matched_labels(signals: list[tuple[str, str]], text: str, matcher) -> list[str]:
    """Return the labels of `signals` whose pattern matches `text` via `matcher`.

    Each signal is tested once (matcher returns bool), preserving the
    one-evidence-line-per-signal semantics of the axis checks. Extracted so the
    check_* functions can run their pattern lists without a per-function
    if/for decision point (CodeScene Complex Method).
    """
    return [label for pattern, label in signals if matcher(pattern, text)]


def _score_from_deductions(deductions: int, *, at_two: int = 3, at_three: int = 2) -> int:
    """Map a deduction count to a base axis score (5 = clean, lower = more).

    `at_two`/`at_three` are the scores for exactly 2 / 3+ deductions so the
    axis-specific severity floors stay explicit at the call site (Completeness
    caps at 3 even for 3+ deductions; the other axes reach 2). Extracted from
    the per-axis if/elif chains (CodeScene Complex Method).

    The heuristic floors at 2 (at_three); score 1 ("fundamentally incorrect"
    per the rubric) requires LLM semantic judgment and cannot be reached by
    keyword counting alone — see the self-check disclosure in format_report().
    """
    if deductions >= 3:
        return at_three
    if deductions == 2:
        return at_two
    if deductions == 1:
        return 4
    return 5


# Mixed-result phrasing the long danger regex may miss, e.g. "10 passed, 1
# failed". Failure count is [1-9]\d* (any non-zero count, not just single digit)
# so "10 passed, 42 failed" is caught; a "0 failed" tail cannot match.
_MIXED_RESULT_RE = re.compile(
    r'(?i)\b\d+\s+passed\b.{0,40}?\b[1-9]\d*\s+(fail|error|failed|failure)'
)
# Unambiguous uncounted failure phrases (Codex P2): "Tests did not pass",
# "pytest failed", "lint failed" — plain phrases without a numeric count that
# still mean failure and must not be treated as merely "unverified" (cap 3).
_UNCOUNTED_FAILURE_RE = re.compile(
    r'(?i)\b(tests?\s+did\s+not\s+pass|pytest\s+failed|lint\s+failed)\b'
)
# A bare "tests failed" is ambiguous: a real failure ("the tests failed",
# "2 tests failed") vs SUCCESS reporting ("0 tests failed", "No tests failed",
# "None of the tests failed", "42 passed, 0 tests failed"). Match it separately
# so the zero/negation prefix guard below can reject the success phrasings —
# the broad danger regexes go through _positive_match for the same reason.
_BARE_TESTS_FAILED_RE = re.compile(
    r'(?i)\btests?\s+failed(?!\s*(?:count|total|summary))\b'
)
# "tests failed" reports success when a zero count or quantity-negation sits
# just BEFORE it ("0 tests failed", "No tests failed") or just AFTER it as a
# count ("Tests failed: 0", "tests failed (0)", "tests failed: none").
_FAILURE_ZERO_PREFIX = re.compile(r"(?i)\b(?:no|none|zero|0)\b[\s\w]{0,15}$")
# `0(?![.\d])` so a duration tail ("tests failed (0.2s)", "tests failed: 0.3s")
# is NOT read as a zero failure count — only a standalone 0/none/zero counts.
_FAILURE_ZERO_SUFFIX = re.compile(r"(?i)^\s*[:=(]?\s*(?:0(?![.\d])|none|zero)\b")


def _bare_tests_failed(text: str) -> bool:
    """True for a real bare "tests failed", False when zero/negation-qualified."""
    for m in _BARE_TESTS_FAILED_RE.finditer(text):
        prefix = text[max(0, m.start() - 30):m.start()]
        if _FAILURE_ZERO_PREFIX.search(prefix):
            continue
        if _FAILURE_ZERO_SUFFIX.search(text[m.end():]):
            continue
        return True
    return False


def _reports_test_failure(text: str, danger_labels: list[str]) -> bool:
    """True when output reports a test/lint failure → forces Accuracy ≤ 2.

    Per the bundled rubric (references/evaluation-criteria.md) a claimed pass
    contradicted by a reported failure is an automatic Accuracy ≤ 2. Covers the
    counted danger-pattern match, mixed results ("10 passed, 1 failed"), and
    uncounted plain phrases — while a zero count or negation ("0 tests failed",
    "No tests failed") correctly does NOT cap.
    """
    return (
        "Failed tests reported" in danger_labels
        or bool(_MIXED_RESULT_RE.search(text))
        or bool(_UNCOUNTED_FAILURE_RE.search(text))
        or _bare_tests_failed(text)
    )


def check_accuracy(text: str) -> AxisScore:
    """Check for verifiable claims, tool output references, error signs."""
    # Positive signals: verified claims
    verified_patterns = [
        (r"(?i)(tests?\s+pass|all\s+tests?\s+passing|[1-9]\d*\s+passed)", "Tests passing"),
        (r"(?i)(exit\s+code\s*[:=]?\s*0|exited\s+with\s+0)", "Clean exit code"),
        (r"(?i)(lint\s+(?:is\s+)?clean|no\s+lint\s+errors|\b0\s+errors\b)", "Lint clean"),
        (r"(?i)(verified|confirmed|validated)\s+(with|against|using|by)", "Explicit verification"),
        (r"(?i)(grep|rg)\s+.*\b(found|matched|returned)", "Grep confirmed"),
    ]
    # Negative signals: unverified claims. Negation-aware (mirror the positive
    # path): a negated defect statement such as "No TODOs remain" or "not
    # untested" must NOT deduct — reusing _positive_match means we only deduct
    # on a non-negated occurrence.
    danger_patterns = [
        (r"(?i)([1-9]\d*\s+tests?\s+(?:failed|failures?|errors?)(?![-\w])|[1-9]\d*\s+failing\s+tests?|\d+\s+passed.{0,30}?[1-9]\d*\s+(?:failed|failures?|errors?)(?![-\w])|[1-9]\d*\s+(?:failed|failures?|errors?)(?![-\w]).{0,30}?\d+\s+passed|(?:pytest|jest|vitest|cargo|unittest).{0,30}?[1-9]\d*\s+(?:failed|failures?|errors?)(?![-\w])|\btests?.{0,10}?[1-9]\d*\s+(?:failed|failures?|errors?)(?![-\w]))", "Failed tests reported"),
        (r"(?i)(should\s+work|probably\s+fine|should\s+be\s+ok)", "Hedged claim without verification"),
        (r"(?i)(I\s+think|I\s+believe|I\s+assume|might\s+be)", "Speculation without evidence"),
        (r"(?i)(untested|not\s+tested|haven'?t\s+tested)", "Explicitly untested"),
        (r"(?i)(\bTODO\b|\bFIXME\b|\bHACK\b|\bWORKAROUND\b)", "Unresolved TODO/FIXME"),
    ]

    positive_labels = _matched_labels(verified_patterns, text, _positive_match)
    danger_labels = _matched_labels(danger_patterns, text, _positive_match)
    evidence = [f"+ {label}" for label in positive_labels]
    evidence.extend(f"- {label}" for label in danger_labels)
    deductions = len(danger_labels)

    score = _score_from_deductions(deductions)

    # A reported test/lint failure is ground truth → automatic Accuracy ≤ 2,
    # even alongside positive "X passed" signals (see _reports_test_failure).
    if _reports_test_failure(text, danger_labels):
        score = min(score, 2)

    # Unverified correctness cannot score as excellent: with no positive
    # verification evidence, cap the score so a terse "Done." earns a 3, not a 5.
    if not positive_labels:
        score = min(score, 3)

    if not evidence:
        evidence.append("No verification signals detected — unverified, score capped")

    result = AxisScore(name="Accuracy", score=score, evidence=evidence)
    if score < 5:
        result.improvement = "Cite specific tool outputs (test results, exit codes, grep findings) to back claims"
    return result


# A handling verb must be bound to "edge/corner cases" for it to count as
# positive coverage — a bare mention ("there might be edge cases with POST")
# is an admission of a GAP, not evidence the cases were handled.
_EDGE_VERB = (
    r"(?:handl(?:e|es|ed|ing)|address(?:|es|ed)|cover(?:|s|ed)|test(?:|s|ed)"
    r"|list(?:|s|ed)|enumerat(?:e|es|ed)|account(?:|ed)\s+for|consider(?:|s|ed))"
)
_EDGE_CASE_HANDLED = (
    rf"(?i)(?:\b{_EDGE_VERB}\s+(?:the\s+|all\s+|these\s+)?(?:edge|corner)\s*cases?"
    rf"|(?:edge|corner)\s*cases?\s+(?:are\s+|were\s+|have\s+been\s+|been\s+)?\b{_EDGE_VERB})"
)


def check_completeness(text: str) -> AxisScore:
    """Check for requirement coverage, edge cases, error handling."""
    # Positive signals. Coverage claims (edge cases, error handling, and the
    # bare "verification" noun) use the absence-aware matcher so an explicit
    # admission such as "error handling is absent", "Verification missing.",
    # or "Verification is absent" is NOT scored present. The bare
    # `verification` token carries a negative lookahead for a trailing absence
    # word ("Verification missing.") while _coverage_match's _ABSENCE_SUFFIX
    # catches the copula form ("Verification is absent"); the verb phrases
    # ("verified that", "confirmed that") stay bare since "verified that
    # nothing is missing" is itself a positive completeness claim.
    coverage_signals = [
        (_EDGE_CASE_HANDLED, "Edge cases addressed"),
        (rf"(?i)(?:{_ERR_HANDLING})", "Error handling present"),
        (
            rf"(?i)(verification(?!\s+(?:{_ABS_BARE})\b)|verified\s+that|confirmed\s+that)",
            "Verification step present",
        ),
    ]
    other_signals = [
        (r"(?i)(all\s+\w+\s+(methods|endpoints|routes))", "Full coverage claimed"),
    ]
    # Gaps
    gap_signals = [
        (r"(?i)(not\s+covered|not\s+handled|out\s+of\s+scope)", "Explicit gap acknowledged"),
        (r"(?i)(only\s+(works|handles|supports)\s+\w+)", "Limited scope noted"),
        (r"(?i)(assume[sd]?\s+that|assuming\s+the)", "Assumption without verification"),
        # Suffix-absence admission, e.g. "error handling is absent",
        # "edge cases: none", "tests have not been done". Uses the same
        # _LINK connector as _ABSENCE_SUFFIX so every positive that
        # _coverage_match suppresses also lands a deduction here (symmetric),
        # while _NEG_GAP omits the bare not-covered/not-handled forms the
        # generic gap above already deducts (no double-count).
        (rf"(?i)(?:{_COVERAGE_NOUNS}){_LINK}(?:{_ABS_BARE}|{_NEG_GAP})\b",
         "Coverage explicitly absent"),
    ]

    positive_labels = _matched_labels(coverage_signals, text, _coverage_match)
    positive_labels += _matched_labels(other_signals, text, _positive_match)
    # Negation-aware, consistent with check_accuracy's danger loop: a negated
    # gap statement ("not out of scope") must NOT deduct.
    gap_labels = _matched_labels(gap_signals, text, _positive_match)
    evidence = [f"+ {label}" for label in positive_labels]
    evidence.extend(f"- {label}" for label in gap_labels)
    deductions = len(gap_labels)

    # Completeness's severity floor is 3 (2+ deductions → 3, never 2): gap
    # signals are weaker indicators than accuracy's danger patterns.
    score = _score_from_deductions(deductions, at_two=3, at_three=3)

    # No positive coverage evidence: cannot score as excellent — fail closed.
    if not positive_labels:
        score = min(score, 3)

    if not evidence:
        evidence.append("No completeness signals — unable to assess coverage")

    result = AxisScore(name="Completeness", score=score, evidence=evidence)
    if score < 5:
        result.improvement = "List what was covered AND what was intentionally excluded, with reasoning"
    return result


JARGON_EXPLANATION_WINDOW = 80
_JARGON_STRONG_MARKER = re.compile(r"(?i)(refers to|i\.e\.|in other words)")
_JARGON_WEAK_MARKER = re.compile(r"(?i)\bmeans\b")
_JARGON_SENTENCE_END = re.compile(r"[!?\n]|\.(?:\s|$)")  # period only when sentence-final, so "i.e." stays intact


def _jargon_pattern_explained(text: str, pattern: str) -> bool:
    """Return True if any occurrence of ``pattern`` in ``text`` is explained.

    An explanation marker must follow the jargon term within the forward
    window (see ``_check_jargon`` for the full rationale).  Strong markers
    match anywhere in the window; the weak marker "means" is restricted to
    the term's own sentence.
    """
    for m in re.finditer(pattern, text, re.IGNORECASE):
        window = text[m.end():m.end() + JARGON_EXPLANATION_WINDOW]
        boundary = _JARGON_SENTENCE_END.search(window)
        same_sentence = window[:boundary.start()] if boundary else window
        if _JARGON_STRONG_MARKER.search(window) or _JARGON_WEAK_MARKER.search(same_sentence):
            return True
    return False


def _check_jargon(text: str, task: Optional[str] = None) -> tuple[int, list[str]]:
    """Return clarity deductions for unexplained domain jargon.

    An explanation marker must follow the jargon term within the remainder
    of the SAME sentence (capped at JARGON_EXPLANATION_WINDOW chars) to
    count as explaining it — the natural "<term> means/refers to/i.e. ..."
    structure. Two earlier bugs are avoided:
      - matching markers against the WHOLE text let a single generic
        "means" anywhere (even an unrelated later sentence) disable the
        check (e.g. "...race condition scenarios. Config means deploy...");
      - including the domain label itself as a marker let the jargon's own
        category name (e.g. "concurrency") count as its explanation.
    Markers are forward-only (an explanation follows the term). Strong,
    explicit markers ("refers to", "i.e.", "in other words") count anywhere
    in the forward window; the weak/common marker "means" is additionally
    restricted to the term's own sentence, so an unrelated later-sentence
    "means" cannot satisfy the check.

    If the input *task* already contains the jargon term, do not penalize
    the output for re-using it without a fresh explanation (task-provided
    jargon case).
    """
    jargon = [
        (r"\b(idempotent|race condition|deadlock|thundering herd)\b", "concurrency"),
        (r"\b(exponential backoff|circuit breaker|bulkhead)\b", "resilience"),
        (r"\b(ACID|CAP|eventual consistency|linearizability)\b", "database theory"),
    ]
    deductions = 0
    evidence = []
    for pattern, domain in jargon:
        if task and re.search(pattern, task, re.IGNORECASE):
            continue  # task already introduced the term; re-use in output is not unexplained jargon
        if re.search(pattern, text, re.IGNORECASE) and not _jargon_pattern_explained(text, pattern):
            deductions += 1
            evidence.append(f"- Domain term used without explanation ({domain})")
    return deductions, evidence


def _check_summary(text: str) -> tuple[int, list[str]]:
    """Return clarity deduction when long output lacks an early summary."""
    summary_terms = ["summary", "tldr", "overview", "in short"]
    has_early_summary = any(term in ' '.join(text.split()[:SUMMARY_CHECK_FIRST_N]).lower() for term in summary_terms)
    if not has_early_summary and count_words(text) > SUMMARY_CHECK_WORDS:
        return 1, ["- No summary/TLDR in first 100 words (text is 300+ words)"]
    return 0, []


def _structure_evidence(text: str) -> list[str]:
    """Return clarity evidence for structural formatting (headings, code, bullets)."""
    evidence = []
    if re.search(r"^#{1,3}\s+", text, re.MULTILINE):
        evidence.append("+ Uses headings for structure")
    if re.search(r"```", text):
        evidence.append("+ Uses code blocks")
    if re.search(r"^\s*[-*]\s+", text, re.MULTILINE):
        evidence.append("+ Uses bullet points")
    return evidence


def _wall_of_text_evidence(text: str) -> tuple[int, list[str]]:
    """Return (1, evidence) when a paragraph exceeds the wall-of-text threshold."""
    for paragraph in [p for p in text.split("\n\n") if p.strip()]:
        if count_words(paragraph) > WALL_OF_TEXT_WORDS:
            return 1, ["- Wall-of-text paragraph (>200 words without break)"]
    return 0, []


def check_clarity(text: str, task: Optional[str] = None) -> AxisScore:
    """Check for structure, readability, jargon handling."""
    evidence = _structure_evidence(text)

    wall_deductions, wall_evidence = _wall_of_text_evidence(text)
    deductions = wall_deductions
    evidence.extend(wall_evidence)

    jargon_deductions, jargon_evidence = _check_jargon(text, task)
    summary_deductions, summary_evidence = _check_summary(text)
    deductions += jargon_deductions + summary_deductions
    evidence.extend(jargon_evidence + summary_evidence)

    score = _score_from_deductions(deductions)

    if not evidence:
        evidence.append("+ Well-structured with no clarity issues detected")

    result = AxisScore(name="Clarity", score=score, evidence=evidence)
    if score < 5:
        result.improvement = "Add headings, break long paragraphs, define domain terms on first use"
    return result


def check_actionability(text: str) -> AxisScore:
    """Check if the user can act on the output immediately."""
    # Positive signals
    actionable_signals = [
        # Tempered gap: the span between the noun and the verb must not cross a
        # negation (shares _NEG_WORDS with the prefix check), so "PR not created",
        # "PR isn't open", "pull request failed to open" do not match — the
        # prefix-only _NEGATION check can't see an interior negation.
        (rf"(?i)(merge|\bPR\b|pull request)(?:(?!\b(?:{_NEG_WORDS})\b).)*?(created|ready|open)", "PR created"),
        (r"(?i)(run|execute)\s+[`\"']?[\w./-]+", "Specific run command given"),
        (r"(?i)(next\s+steps?|follow[- ]up|what\s+to\s+do)", "Next steps provided"),
        (r"(?i)(file\s+(created|written|modified|updated)\s+at)", "File path specified"),
    ]
    # Negative signals (negation-aware, consistent with check_accuracy's danger loop).
    vague_signals = [
        (r"(?i)(you\s+(should|could|might\s+want\s+to))\s+\w+", "Vague suggestion without specifics"),
        (r"(?i)(consider|maybe|perhaps)\s+\w+ing", "Non-committal suggestion"),
        (r"(?i)(figure\s+out|look\s+into|investigate)\s", "Defers work to user"),
    ]

    positive_labels = _matched_labels(actionable_signals, text, _positive_match)
    vague_labels = _matched_labels(vague_signals, text, _positive_match)
    evidence = [f"+ {label}" for label in positive_labels]
    evidence.extend(f"- {label}" for label in vague_labels)
    deductions = len(vague_labels)

    score = _score_from_deductions(deductions)

    # No positive actionability evidence: cannot score as excellent — fail closed.
    if not positive_labels:
        score = min(score, 3)

    if not evidence:
        evidence.append("No actionability signals — user may need to ask 'what now?'")

    result = AxisScore(name="Actionability", score=score, evidence=evidence)
    if score < 5:
        result.improvement = "End with a single clear action: 'Merge this PR', 'Run ./deploy.sh', or 'Review the 3 changed files'"
    return result


def _ratio_evidence(text: str, task: Optional[str]) -> tuple[int, list[str]]:
    """Return (score cap, evidence) from the task-to-output length ratio.

    A high ratio (output much longer than the task) caps the conciseness score.
    Extracted from check_conciseness to flatten its conditional nesting
    (CodeScene Complex Method). Returns (5, []) when there is no task context.
    """
    if not task:
        return 5, []
    wc = count_words(text)
    task_wc = count_words(task)
    ratio = wc / max(task_wc, 1)
    if ratio > TASK_OUTPUT_RATIO_HIGH:
        return 3, [f"- Output is {ratio:.0f}x longer than task description (high ratio)"]
    if ratio > TASK_OUTPUT_RATIO_MEDIUM:
        return 4, [f"- Output is {ratio:.0f}x longer than task description"]
    return 5, []


def _redundancy_evidence(text: str) -> tuple[int, list[str]]:
    """Return (count, evidence) for redundancy patterns appearing >2 times.

    Extracted from check_conciseness to reduce its cyclomatic complexity
    (CodeScene Complex Method).
    """
    redundancy_checks = [
        (r"(?i)(as\s+(I|we)\s+(mentioned|said|noted|discussed)\s+(earlier|above|before))",
         "Refers back to earlier statement (possible repetition)"),
        (r"(?i)(to\s+summarize|in\s+summary|in\s+conclusion|to\s+conclude)",
         "Has explicit summary (good if needed, flag if redundant)"),
        (r"(?i)(let\s+me\s+(explain|break\s+this\s+down|walk\s+you\s+through))",
         "Meta-commentary adds words without information"),
    ]
    redundant_count = 0
    evidence: list[str] = []
    for pattern, label in redundancy_checks:
        matches = re.findall(pattern, text)
        if len(matches) > 2:
            redundant_count += 1
            evidence.append(f"- '{label}' appears {len(matches)} times")
    return redundant_count, evidence


def check_conciseness(text: str, task: Optional[str] = None) -> AxisScore:
    """Check for redundancy, filler, information density."""
    evidence: list[str] = []
    score = 5

    # Heuristic: task-to-output ratio
    ratio_cap, ratio_evidence = _ratio_evidence(text, task)
    score = min(score, ratio_cap)
    evidence.extend(ratio_evidence)

    # Redundancy signals
    redundant_count, redundancy_evidence = _redundancy_evidence(text)
    evidence.extend(redundancy_evidence)
    if redundant_count >= 2:
        score = min(score, 3)
    elif redundant_count == 1:
        score = min(score, 4)

    if not evidence and score == 5:
        evidence.append("+ No redundancy detected. Information density appears good.")

    result = AxisScore(name="Conciseness", score=score, evidence=evidence)
    if score < 5:
        result.improvement = "Cut meta-commentary, remove repeated points, trim examples to one representative case"
    return result


def evaluate(task: Optional[str], output: str) -> list[AxisScore]:
    """Run all 5 axis checks and return scored results."""
    return [
        check_accuracy(output),
        check_completeness(output),
        check_clarity(output, task),
        check_actionability(output),
        check_conciseness(output, task),
    ]


def _critical_lines(scores: list[AxisScore]) -> list[str]:
    """Render the CRITICAL ISSUES (axes ≤ 2) block."""
    lines = ["CRITICAL ISSUES (axes ≤ 2):"]
    critical = [(s, s.improvement or "No improvement suggested") for s in scores if s.score <= 2]
    if critical:
        for s, imp in critical:
            lines.append(f"  [{s.name}] Score {s.score}/5 — {imp}")
    else:
        lines.append("  None")
    return lines


def _improvement_lines(scores: list[AxisScore]) -> list[str]:
    """Render the TOP IMPROVEMENTS block (axes < 4, ranked by score)."""
    improvements = [(s, s.improvement) for s in scores if s.improvement and s.score < 4]
    lines = ["TOP IMPROVEMENTS:"]
    if improvements:
        for i, (s, imp) in enumerate(sorted(improvements, key=lambda x: x[0].score), 1):
            lines.append(f"  {i}. [{s.name}] {imp}")
    else:
        lines.append("  No axes below 4. Strong output across all dimensions.")
    return lines


def _compute_verdict(scores: list[AxisScore], avg: float) -> str:
    """Pick the overall verdict string from the per-axis scores."""
    min_score = min(s.score for s in scores)
    if min_score <= 2:
        return f"Redo with specific fixes. Weakest axis: {min(scores, key=lambda s: s.score).name} ({min_score}/5)."
    if any(s.score <= 3 for s in scores):
        weak = [s.name for s in scores if s.score <= 3]
        return f"Fix {'/'.join(weak)} issues, then deliver."
    if avg >= 4.5:
        return "Deliver as-is. No changes needed."
    return "Deliver as-is. Minor improvements noted above."


def format_report(scores: list[AxisScore]) -> str:
    """Format scores into a readable evaluation report."""
    avg = sum(s.score for s in scores) / len(scores)
    lines = []
    lines.append("=" * 60)
    lines.append("AGENT SELF-EVALUATION REPORT")
    lines.append("=" * 60)
    lines.append(f"Summary: Overall score {avg:.1f}/5 across 5 quality axes.")
    lines.append("")

    for s in scores:
        bar = "█" * s.score + "░" * (5 - s.score)
        lines.append(f"  {s.name:<15} {bar} {s.score}/5")
        lines.extend(f"    {e}" for e in s.evidence)
        if s.improvement:
            lines.append(f"    → {s.improvement}")
        lines.append("")

    lines.append(f"  {'OVERALL':<15} {avg:.1f}/5")
    lines.append("")

    # Critical issues, self-check, top improvements, and verdict are each
    # rendered by a dedicated helper so this function stays a flat assembly
    # loop (CodeScene Complex Method / Bumpy Road Ahead).
    lines.extend(_critical_lines(scores))
    lines.append("")
    lines.append(
        "Self-check: heuristic first-pass scores (keyword + structural). "
        "Confirm borderline axes against the actual task before acting; "
        "pair with an LLM judge for semantic accuracy."
    )
    lines.append("")
    lines.extend(_improvement_lines(scores))
    lines.append("")
    lines.append(f"VERDICT: {_compute_verdict(scores, avg)}")

    return "\n".join(lines)


def _looks_like_path(path: str) -> bool:
    """Heuristic: does `path` look like a file path rather than inline text?

    True when it contains a path separator or ends in a short extension, so a
    typo like `--task taks.txt` is flagged rather than silently evaluated as
    literal text. Extracted from _read_file_or_text to keep its conditional
    shallow (CodeScene Complex Conditional).
    """
    return "/" in path or "\\" in path or bool(re.search(r"\.[A-Za-z0-9]{1,5}$", path))


def _handle_missing_file(path: str, required: bool) -> Optional[str]:
    """Handle a FileNotFoundError: hard-error if required, else treat as inline text."""
    if required:
        print(f"Error: output file '{path}' not found", file=sys.stderr)
        sys.exit(1)
    # Not required: fall back to treating the value as inline text, but warn
    # when it looks like a mistyped path (has a separator or file extension)
    # so a typo like `--task taks.txt` is not silently evaluated as literal text.
    if _looks_like_path(path):
        print(
            f"Warning: '{path}' looks like a file path but was not found; "
            "treating it as inline text",
            file=sys.stderr,
        )
    return path


def _read_file_or_text(path: Optional[str], *, required: bool = False) -> Optional[str]:
    """Read a file path or return inline text when allowed."""
    if path is None:
        return None
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return _handle_missing_file(path, required)
    except OSError as exc:
        # Non-missing read failures (PermissionError, IsADirectoryError, …) are
        # hard errors, not "treat as inline text" cases — the path resolves to a
        # real filesystem object that cannot be read.
        print(f"Error: unable to read '{path}': {exc}", file=sys.stderr)
        sys.exit(1)


def _read_input(args: argparse.Namespace) -> tuple[Optional[str], str]:
    """Read task and output for interactive, file, or pipe mode."""
    if args.interactive:
        task = input("Task description: ").strip()
        print("Paste agent output (Ctrl+D to finish):")
        return task, sys.stdin.read()
    if args.output:
        return _read_file_or_text(args.task), _read_file_or_text(args.output, required=True) or ""
    return _read_file_or_text(args.task), sys.stdin.read()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Evaluate agent output against the 5-axis rubric"
    )
    parser.add_argument("--task", help="Task description (file path or inline text)")
    # --output and --interactive are mutually exclusive so passing both cannot
    # silently let --interactive shadow --output (or vice-versa).
    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument("--output", help="Agent output to evaluate (file path)")
    mode_group.add_argument("--interactive", action="store_true", help="Prompt for task and read output from stdin")
    args = parser.parse_args()

    task, output = _read_input(args)
    if not output:
        print("Error: no output to evaluate", file=sys.stderr)
        sys.exit(1)

    scores = evaluate(task, output)
    print(format_report(scores))


if __name__ == "__main__":
    main()
