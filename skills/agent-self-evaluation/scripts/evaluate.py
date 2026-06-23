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
_NEGATION = re.compile(rf"(?i)\b(?:{_NEG_WORDS})\b[\s\w]{{0,15}}$")


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


def check_accuracy(text: str) -> AxisScore:
    """Check for verifiable claims, tool output references, error signs."""
    evidence = []
    deductions = 0
    score = 5

    # Positive signals: verified claims
    verified_patterns = [
        (r"(?i)(tests?\s+pass|all\s+tests?\s+passing|[1-9]\d*\s+passed)", "Tests passing"),
        (r"(?i)(exit\s+code\s*[:=]?\s*0|exited\s+with\s+0)", "Clean exit code"),
        (r"(?i)(lint\s+(?:is\s+)?clean|no\s+lint\s+errors|\b0\s+errors\b)", "Lint clean"),
        (r"(?i)(verified|confirmed|validated)\s+(with|against|using|by)", "Explicit verification"),
        (r"(?i)(grep|rg)\s+.*\b(found|matched|returned)", "Grep confirmed"),
    ]
    for pattern, label in verified_patterns:
        if _positive_match(pattern, text):
            evidence.append(f"+ {label}")

    # Negative signals: unverified claims
    danger_patterns = [
        (r"(?i)(should\s+work|probably\s+fine|should\s+be\s+ok)", "Hedged claim without verification"),
        (r"(?i)(I\s+think|I\s+believe|I\s+assume|might\s+be)", "Speculation without evidence"),
        (r"(?i)(untested|not\s+tested|haven'?t\s+tested)", "Explicitly untested"),
        (r"(?i)(TODO|FIXME|HACK|WORKAROUND)", "Unresolved TODO/FIXME"),
    ]
    for pattern, label in danger_patterns:
        # Negation-aware (mirror the positive path): a negated defect statement
        # such as "No TODOs remain" or "not untested" must NOT deduct. Reusing
        # _positive_match means we only deduct on a non-negated occurrence.
        if _positive_match(pattern, text):
            deductions += 1
            evidence.append(f"- {label}")

    positives = [e for e in evidence if e.startswith("+")]

    if deductions >= 3:
        score = 2
    elif deductions == 2:
        score = 3
    elif deductions == 1:
        score = 4

    # Unverified correctness cannot score as excellent: with no positive
    # verification evidence, cap the score so a terse "Done." earns a 3, not a 5.
    if not positives:
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
    rf"(?i)(?:{_EDGE_VERB}\s+(?:the\s+|all\s+|these\s+)?(?:edge|corner)\s*cases?"
    rf"|(?:edge|corner)\s*cases?\s+(?:are\s+|were\s+|have\s+been\s+|been\s+)?{_EDGE_VERB})"
)


def check_completeness(text: str) -> AxisScore:
    """Check for requirement coverage, edge cases, error handling."""
    evidence = []
    score = 5

    # Positive signals
    completeness_signals = [
        (_EDGE_CASE_HANDLED, "Edge cases addressed"),
        (r"(?i)(error\s*handling|exception\s*handling|try/except|try\s*{)", "Error handling present"),
        (r"(?i)(all\s+\w+\s+(methods|endpoints|routes))", "Full coverage claimed"),
        (r"(?i)(verification|verified\s+that|confirmed\s+that)", "Verification step present"),
    ]
    for pattern, label in completeness_signals:
        if _positive_match(pattern, text):
            evidence.append(f"+ {label}")

    # Gaps
    gap_signals = [
        (r"(?i)(not\s+covered|not\s+handled|out\s+of\s+scope)", "Explicit gap acknowledged"),
        (r"(?i)(only\s+(works|handles|supports)\s+\w+)", "Limited scope noted"),
        (r"(?i)(assume[sd]?\s+that|assuming\s+the)", "Assumption without verification"),
    ]
    deductions = 0
    for pattern, label in gap_signals:
        # Negation-aware, consistent with check_accuracy's danger loop: a
        # negated gap statement ("not out of scope") must NOT deduct.
        if _positive_match(pattern, text):
            deductions += 1
            evidence.append(f"- {label}")

    positives = [e for e in evidence if e.startswith("+")]

    if deductions >= 2:
        score = 3
    elif deductions == 1:
        score = 4

    # No positive coverage evidence: cannot score as excellent — fail closed.
    if not positives:
        score = min(score, 3)

    if not evidence:
        evidence.append("No completeness signals — unable to assess coverage")

    result = AxisScore(name="Completeness", score=score, evidence=evidence)
    if score < 5:
        result.improvement = "List what was covered AND what was intentionally excluded, with reasoning"
    return result


JARGON_EXPLANATION_WINDOW = 80


def _check_jargon(text: str) -> tuple[int, list[str]]:
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
    """
    jargon = [
        (r"\b(idempotent|race condition|deadlock|thundering herd)\b", "concurrency"),
        (r"\b(exponential backoff|circuit breaker|bulkhead)\b", "resilience"),
        (r"\b(ACID|CAP|eventual consistency|linearizability)\b", "database theory"),
    ]
    strong_marker = re.compile(r"(?i)(refers to|i\.e\.|in other words)")
    weak_marker = re.compile(r"(?i)\bmeans\b")
    sentence_end = re.compile(r"[!?\n]|\.(?:\s|$)")  # period only when sentence-final, so "i.e." stays intact
    deductions = 0
    evidence = []
    for pattern, domain in jargon:
        explained = False
        seen = False
        for m in re.finditer(pattern, text, re.IGNORECASE):
            seen = True
            window = text[m.end():m.end() + JARGON_EXPLANATION_WINDOW]
            boundary = sentence_end.search(window)
            same_sentence = window[:boundary.start()] if boundary else window
            if strong_marker.search(window) or weak_marker.search(same_sentence):
                explained = True
                break
        if seen and not explained:
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


def check_clarity(text: str) -> AxisScore:
    """Check for structure, readability, jargon handling."""
    evidence = []
    deductions = 0

    if re.search(r"^#{1,3}\s+", text, re.MULTILINE):
        evidence.append("+ Uses headings for structure")
    if re.search(r"```", text):
        evidence.append("+ Uses code blocks")
    if re.search(r"^\s*[-*]\s+", text, re.MULTILINE):
        evidence.append("+ Uses bullet points")

    for paragraph in [p for p in text.split("\n\n") if p.strip()]:
        if count_words(paragraph) > WALL_OF_TEXT_WORDS:
            deductions += 1
            evidence.append("- Wall-of-text paragraph (>200 words without break)")
            break

    jargon_deductions, jargon_evidence = _check_jargon(text)
    summary_deductions, summary_evidence = _check_summary(text)
    deductions += jargon_deductions + summary_deductions
    evidence.extend(jargon_evidence + summary_evidence)

    if deductions >= 3:
        score = 2
    elif deductions == 2:
        score = 3
    elif deductions == 1:
        score = 4
    else:
        score = 5

    if not evidence:
        evidence.append("+ Well-structured with no clarity issues detected")

    result = AxisScore(name="Clarity", score=score, evidence=evidence)
    if score < 5:
        result.improvement = "Add headings, break long paragraphs, define domain terms on first use"
    return result


def check_actionability(text: str) -> AxisScore:
    """Check if the user can act on the output immediately."""
    evidence = []
    score = 5
    deductions = 0

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
    for pattern, label in actionable_signals:
        if _positive_match(pattern, text):
            evidence.append(f"+ {label}")

    # Negative signals
    vague_signals = [
        (r"(?i)(you\s+(should|could|might\s+want\s+to))\s+\w+", "Vague suggestion without specifics"),
        (r"(?i)(consider|maybe|perhaps)\s+\w+ing", "Non-committal suggestion"),
        (r"(?i)(figure\s+out|look\s+into|investigate)\s", "Defers work to user"),
    ]
    for pattern, label in vague_signals:
        # Negation-aware, consistent with check_accuracy's danger loop.
        if _positive_match(pattern, text):
            deductions += 1
            evidence.append(f"- {label}")

    positives = [e for e in evidence if e.startswith("+")]

    if deductions >= 3:
        score = 2
    elif deductions == 2:
        score = 3
    elif deductions == 1:
        score = 4

    # No positive actionability evidence: cannot score as excellent — fail closed.
    if not positives:
        score = min(score, 3)

    if not evidence:
        evidence.append("No actionability signals — user may need to ask 'what now?'")

    result = AxisScore(name="Actionability", score=score, evidence=evidence)
    if score < 5:
        result.improvement = "End with a single clear action: 'Merge this PR', 'Run ./deploy.sh', or 'Review the 3 changed files'"
    return result


def check_conciseness(text: str, task: Optional[str] = None) -> AxisScore:
    """Check for redundancy, filler, information density."""
    evidence = []
    score = 5
    wc = count_words(text)

    # Heuristic: task-to-output ratio
    if task:
        task_wc = count_words(task)
        ratio = wc / max(task_wc, 1)
        if ratio > TASK_OUTPUT_RATIO_HIGH:
            evidence.append(f"- Output is {ratio:.0f}x longer than task description (high ratio)")
            score = min(score, 3)
        elif ratio > TASK_OUTPUT_RATIO_MEDIUM:
            evidence.append(f"- Output is {ratio:.0f}x longer than task description")
            score = min(score, 4)

    # Redundancy signals
    redundancy_checks = [
        (r"(?i)(as\s+(I|we)\s+(mentioned|said|noted|discussed)\s+(earlier|above|before))",
         "Refers back to earlier statement (possible repetition)"),
        (r"(?i)(to\s+summarize|in\s+summary|in\s+conclusion|to\s+conclude)",
         "Has explicit summary (good if needed, flag if redundant)"),
        (r"(?i)(let\s+me\s+(explain|break\s+this\s+down|walk\s+you\s+through))",
         "Meta-commentary adds words without information"),
    ]
    redundant_count = 0
    for pattern, label in redundancy_checks:
        matches = re.findall(pattern, text)
        if len(matches) > 2:
            redundant_count += 1
            evidence.append(f"- '{label}' appears {len(matches)} times")

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
        check_clarity(output),
        check_actionability(output),
        check_conciseness(output, task),
    ]


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

    # Critical issues (axes ≤ 2)
    critical = [(s, s.improvement or "No improvement suggested") for s in scores if s.score <= 2]
    lines.append("CRITICAL ISSUES (axes ≤ 2):")
    if critical:
        for s, imp in critical:
            lines.append(f"  [{s.name}] Score {s.score}/5 — {imp}")
    else:
        lines.append("  None")

    lines.append("")
    lines.append(
        "Self-check: heuristic first-pass scores (keyword + structural). "
        "Confirm borderline axes against the actual task before acting; "
        "pair with an LLM judge for semantic accuracy."
    )
    lines.append("")

    # Top improvements (axes scoring < 4, ranked by impact)
    improvements = [(s, s.improvement) for s in scores if s.improvement and s.score < 4]
    lines.append("TOP IMPROVEMENTS:")
    if improvements:
        for i, (s, imp) in enumerate(sorted(improvements, key=lambda x: x[0].score), 1):
            lines.append(f"  {i}. [{s.name}] {imp}")
    else:
        lines.append("  No axes below 4. Strong output across all dimensions.")

    lines.append("")

    # Verdict
    min_score = min(s.score for s in scores)
    if min_score <= 2:
        verdict = f"Redo with specific fixes. Weakest axis: {min(scores, key=lambda s: s.score).name} ({min_score}/5)."
    elif any(s.score <= 3 for s in scores):
        weak = [s.name for s in scores if s.score <= 3]
        verdict = f"Fix {'/'.join(weak)} issues, then deliver."
    elif avg >= 4.5:
        verdict = "Deliver as-is. No changes needed."
    else:
        verdict = "Deliver as-is. Minor improvements noted above."
    lines.append(f"VERDICT: {verdict}")

    return "\n".join(lines)


def _read_file_or_text(path: Optional[str], *, required: bool = False) -> Optional[str]:
    """Read a file path or return inline text when allowed."""
    if path is None:
        return None
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        if required:
            print(f"Error: output file '{path}' not found", file=sys.stderr)
            sys.exit(1)
        # Not required: fall back to treating the value as inline text, but warn
        # when it looks like a mistyped path (has a separator or file extension)
        # so a typo like `--task taks.txt` is not silently evaluated as literal text.
        if "/" in path or "\\" in path or re.search(r"\.[A-Za-z0-9]{1,5}$", path):
            print(
                f"Warning: '{path}' looks like a file path but was not found; "
                "treating it as inline text",
                file=sys.stderr,
            )
        return path


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
    parser.add_argument("--output", help="Agent output to evaluate (file path)")
    parser.add_argument("--interactive", action="store_true", help="Prompt for task and read output from stdin")
    args = parser.parse_args()

    task, output = _read_input(args)
    if not output:
        print("Error: no output to evaluate", file=sys.stderr)
        sys.exit(1)

    scores = evaluate(task, output)
    print(format_report(scores))


if __name__ == "__main__":
    main()
