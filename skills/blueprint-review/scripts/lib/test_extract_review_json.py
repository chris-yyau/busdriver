"""Tests for extract_review_json — the shared reviewer-output extractor.

Regression coverage for #503: every droid rescue in the repo's review history
died at this extractor, discarding complete, valid reviews (one with 15 issues).
Two gaps caused it — no fenced-block strategy, and a brace matcher that counted
braces inside string literals.
"""

import json

import extract_review_json as ex

VERDICT = {
    "reviewer_id": "codex",
    "status": "FAIL",
    "issues": [
        {
            # Braces inside a string value: the shape that desynced the old
            # brace-counting matcher. One sampled artifact had 65 of these.
            #
            # They must be NET-unbalanced to pin the bug. A quoted `${x}` or
            # `{ a: false }` balances out, and so does one stray `{` paired with
            # one stray `}` — in all those cases the old string-oblivious counter
            # still landed on the right boundary, so a fixture built from them
            # passes against the very code this file is a regression test for
            # (measured, both fenced and bare). Exactly one unterminated brace is
            # what quoting a code fragment really looks like, and it is what broke
            # extraction in the wild.
            "description": "the block opens with `if (ready) {` and never closes",
            "severity": "HIGH",
        }
    ],
    "metadata": {"total_sections_reviewed": 14},
}

PRETTY = json.dumps(VERDICT, indent=2)


def test_fenced_block_with_prose_preamble():
    """Droid's actual shape: conversational prose, then a ```json fence."""
    raw = f"My review is complete. Here is the verdict:\n\n```json\n{PRETTY}\n```\n"
    assert ex.extract_from_text(raw) == VERDICT


def test_bare_fence_without_language_tag():
    raw = f"done\n\n```\n{PRETTY}\n```\n"
    assert ex.extract_from_text(raw) == VERDICT


def test_pretty_printed_without_fence_survives_braces_in_strings():
    """No fence: the string-aware brace matcher must still find the boundary."""
    raw = f"[info] loading session\nReview follows.\n{PRETTY}\n\ntokens used: 8123\n"
    assert ex.extract_from_text(raw) == VERDICT


def test_unbalanced_quote_in_prose_does_not_desync_scan():
    """A lone `"` in the preamble must not swallow the payload."""
    raw = f'I checked the "status field and the rest.\n{PRETTY}\n'
    assert ex.extract_from_text(raw) == VERDICT


def test_single_line_verdict_still_extracted():
    """The pre-existing line-scan path must keep working."""
    raw = f"warning: config not found\n{json.dumps(VERDICT)}\nusage: 4011 tokens\n"
    assert ex.extract_from_text(raw) == VERDICT


def test_whole_file_clean_json():
    assert ex.extract_from_text(PRETTY) == VERDICT


def test_interleaved_exec_output_with_unmatched_braces():
    """Code snippets echoed by the CLI leave stray braces in the transcript."""
    raw = f"$ grep -n 'fn(' src.ts\n12: const f = (a) => {{ return a; }}\n" f"14: }}\n\n{PRETTY}\n"
    assert ex.extract_from_text(raw) == VERDICT


def test_non_review_json_is_not_returned():
    """A config/usage object must not be mistaken for a verdict."""
    raw = '{"model": "codex", "tokens": 900}\nno review produced\n'
    assert ex.extract_from_text(raw) is None


def test_malformed_fence_payload_reports_why():
    """Distinguish 'found it and it is broken' from 'never found it' (#503)."""
    broken = PRETTY.replace('"severity": "HIGH"', '"severity": "HIGH",,')
    raw = f"```json\n{broken}\n```\n"
    assert ex.extract_from_text(raw) is None
    assert "malformed" in ex.failure_reason()


def test_missing_payload_reports_not_found():
    assert ex.extract_from_text("no JSON here at all\n") is None
    assert ex.failure_reason() == "no review JSON found in output"


def test_failure_reason_resets_between_runs():
    """A stale error from a prior file must not leak into the next reason."""
    ex.extract_from_text("```json\n{,}\n```\n")
    assert ex.extract_from_text("nothing\n") is None
    assert ex.failure_reason() == "no review JSON found in output"


def test_last_verdict_wins_when_output_holds_two():
    """A retry appends; the final verdict is the operative one."""
    first = dict(VERDICT, status="PASS", issues=[])
    raw = f"```json\n{json.dumps(first, indent=2)}\n```\nretrying\n```json\n{PRETTY}\n```\n"
    assert ex.extract_from_text(raw)["status"] == "FAIL"


def test_last_verdict_wins_across_different_shapes():
    """Final-verdict-wins must hold when the two verdicts are shaped differently.

    An early fenced PASS followed by a late single-line FAIL: a chain ordered by
    per-strategy 'reliability' returns the stale PASS, because whichever strategy
    recognises its shape first wins regardless of where it sits in the transcript.
    """
    stale = dict(VERDICT, status="PASS", issues=[])
    raw = (
        f"first attempt\n```json\n{json.dumps(stale, indent=2)}\n```\n"
        f"retrying after correction\n{json.dumps(VERDICT)}\n"
    )
    assert ex.extract_from_text(raw)["status"] == "FAIL"


def test_fenced_pass_does_not_beat_later_pretty_fail():
    """Same ordering trap, both verdicts multi-line."""
    stale = dict(VERDICT, status="PASS", issues=[])
    raw = f"```json\n{json.dumps(stale, indent=2)}\n```\nsuperseded\n{PRETTY}\n"
    assert ex.extract_from_text(raw)["status"] == "FAIL"


def test_brace_heavy_output_does_not_stall():
    """Bound the scan: every '{' used to start a fresh full-length rescan.

    20KB of unmatched opening braces measured ~4.2s before the prefilter, and the
    extractor call sits unbounded on the review path.
    """
    import time

    raw = "{" * 20_000 + "\nno verdict here\n"
    start = time.monotonic()
    assert ex.extract_from_text(raw) is None
    # Deliberately loose. The pre-fix quadratic took ~4.2s on this input and
    # degrades far worse under CI coverage instrumentation, while the fixed path
    # is ~0.1s — so a wide ceiling still catches the regression without turning a
    # shared runner's scheduling noise into a red build.
    assert time.monotonic() - start < 10.0


def test_pathological_brace_preamble_fails_closed_not_open():
    """Thousands of unclosed braces before a verdict: refuse, never fabricate.

    Nesting is genuinely unresolvable here, and defending this shape would demand
    either unbounded scanning or stepping blindly into regions — the fail-open the
    guards above exist to stop. Realistic noise levels are covered by
    test_brace_noise_before_a_clean_verdict_is_tolerated; this pins the direction
    the extractor breaks in when structure cannot be established at all.
    """
    raw = "{" * 5_000 + f"\ntranscript noise\n{PRETTY}\n"
    assert ex.extract_from_text(raw) is None


def test_nested_pass_does_not_shadow_the_enclosing_fail():
    """FAIL-OPEN GUARD: a nested review-shaped object must never be the verdict.

    A verdict whose metadata ends with {"status": "PASS", "issues": []} is the
    dangerous shape: scanning '{' backwards reaches that inner object first, and
    _bp_droid_rescue would retag and accept it as a PASS.
    """
    verdict = {
        "reviewer_id": "codex",
        "status": "FAIL",
        "issues": [{"description": "real finding", "severity": "HIGH"}],
        "metadata": {"prior_run": {"status": "PASS", "issues": []}},
    }
    raw = f"review follows\n{json.dumps(verdict, indent=2)}\n"
    got = ex.extract_from_text(raw)
    assert got["status"] == "FAIL"
    assert got == verdict


def test_review_keyed_unmatched_objects_do_not_stall():
    """The pathological case a naive key-prefilter does NOT bound.

    Repeating an unterminated `{"status": null` keeps every candidate looking
    plausible, so a prefilter on review keys alone still rescans the remaining
    text per candidate (measured ~3s at 68KB, growing ~4x per doubling).
    """
    import time

    raw = '{"status": null ' * 4_000 + "\nno verdict\n"
    start = time.monotonic()
    assert ex.extract_from_text(raw) is None
    assert time.monotonic() - start < 10.0  # loose on purpose — see above


def test_plain_code_fence_is_not_reported_as_a_broken_review():
    """A shell/Python fence is not a malformed verdict — say so accurately."""
    raw = "here is the command\n```\nfor f in *.py; do echo $f; done\n```\n"
    assert ex.extract_from_text(raw) is None
    assert ex.failure_reason() == "no review JSON found in output"


def test_malformed_outer_verdict_does_not_expose_its_nested_pass():
    """FAIL-OPEN GUARD, error path: skipping decoded objects is not enough.

    When the OUTER verdict fails to decode (one trailing comma does it), advancing
    a single character walks into it, and the nested {"status": "PASS"} decodes
    cleanly as a top-level candidate. Must fail closed, not surface the PASS.
    """
    raw = (
        'review:\n{"reviewer_id": "codex", "status": "FAIL", '
        '"issues": [{"description": "real", "severity": "HIGH"}], '
        '"metadata": {"status": "PASS", "issues": []},}\n'
    )
    assert ex.extract_from_text(raw) is None
    assert "malformed" in ex.failure_reason()


def test_malformed_unfenced_verdict_reports_malformed():
    """The diagnostic contract must hold for every shape, not just fenced ones."""
    raw = 'prose\n{"reviewer_id": "codex", "status": "FAIL", "issues": [],,}\n'
    assert ex.extract_from_text(raw) is None
    assert "malformed" in ex.failure_reason()


def test_stale_pass_does_not_stand_in_for_a_malformed_later_verdict():
    """FAIL-OPEN GUARD: the LAST verdict is operative, even when unreadable.

    An earlier clean PASS followed by a malformed later verdict must not exit 0
    with the stale PASS — the retry may well be a FAIL. Fail closed instead.
    """
    stale = dict(VERDICT, status="PASS", issues=[])
    raw = (
        f"{json.dumps(stale)}\nretrying\n"
        '{"reviewer_id": "codex", "status": "FAIL", "issues": [],,}\n'
    )
    assert ex.extract_from_text(raw) is None
    assert "malformed" in ex.failure_reason()


def test_early_syntax_error_does_not_expose_a_nested_pass():
    """FAIL-OPEN GUARD: outer malforms BEFORE naming any verdict key.

    The consumed prefix carries no reviewer_id/issues, so the malformed-verdict
    branch cannot classify it. Stepping over the whole region is what stops the
    nested {"status": "PASS"} from being promoted to a top-level candidate.
    """
    raw = 'out:\n{"a": 1,, "metadata": {"status": "PASS", "issues": []}}\n'
    assert ex.extract_from_text(raw) is None


def test_array_wrapped_verdict_is_not_read_as_top_level():
    """FAIL-OPEN GUARD: `[{...}]` — sweeping only '{' decodes the ELEMENT.

    An array is a region like any other; starting inside it promotes a nested
    element to top-level verdict, and the rescue accepts the fabricated PASS.
    """
    wrapped = dict(VERDICT, status="PASS", issues=[])
    raw = f"output:\n[{json.dumps(wrapped)}]\n"
    assert ex.extract_from_text(raw) is None


def test_malformed_attempt_then_corrected_verdict_uses_the_correction():
    """A retry after a botched emit must be read — failing closed on the earlier
    malformed attempt would discard a review that is right there."""
    raw = (
        '{"reviewer_id": "codex", "status": "FAIL", "issues": [],,}\n'
        f"correcting\n{json.dumps(VERDICT)}\n"
    )
    assert ex.extract_from_text(raw) == VERDICT


def test_malformed_verdict_erroring_before_its_keys_still_fails_closed():
    """Where the syntax error falls must not decide the outcome.

    Erroring before `reviewer_id` appears used to read as incidental prose, so an
    earlier clean PASS was returned in place of the malformed later verdict.
    """
    stale = dict(VERDICT, status="PASS", issues=[])
    raw = (
        f"{json.dumps(stale)}\nretrying\n"
        '{"a": 1,, "reviewer_id": "codex", "status": "FAIL", "issues": []}\n'
    )
    assert ex.extract_from_text(raw) is None


def test_prose_mentioning_status_does_not_abort_the_sweep():
    """A diagnostic line is not a broken verdict — losing the review to it would
    recreate exactly the #503 failure this change exists to fix."""
    raw = f'config = {{"status": pending}}\nlater:\n{json.dumps(VERDICT)}\n'
    assert ex.extract_from_text(raw) == VERDICT


def test_randomised_transcripts_never_fabricate_a_verdict():
    """Property check over generated noise — no dependency, fixed seed.

    The invariant that matters is one-directional: the extractor may decline to
    find a verdict, but it must never invent one, and whatever it returns must be
    the verdict actually embedded in the transcript.
    """
    import random

    rng = random.Random(20260728)
    noise_pool = [
        'he said "unterminated',
        "code: if (x) { return; }",
        "stray }",
        "```",
        "```json",
        'escaped \\" quote',
        "{",
        "}",
        '{"status": null',
        "tokens used: 4011",
        "{}",
        '{"unrelated": {"nested": 1}}',
    ]
    for _ in range(300):
        noise = "\n".join(rng.choice(noise_pool) for _ in range(rng.randint(0, 12)))
        embed = rng.random() < 0.5
        payload = json.dumps(VERDICT, indent=rng.choice([None, 2])) if embed else ""
        raw = f"{noise}\n{payload}\n{rng.choice(noise_pool)}\n"
        got = ex.extract_from_text(raw)
        if got is not None:
            # Never a fabrication, and never a fragment promoted to a verdict.
            assert got == VERDICT, raw
        if not embed:
            assert got is None, raw


def test_brace_noise_cannot_disarm_the_nested_pass_guard():
    """REGRESSION: bounding the region skip must not become a fail-open.

    A character budget made this scenario extract the nested PASS: a couple of
    stray braces in the preamble exhausted it, after which the malformed outer
    verdict was stepped INTO rather than over. Short fixtures never reached the
    budget, so the other fail-open tests could not see it — this one carries
    enough preamble noise to exhaust any such allowance.
    """
    noise = "\n".join(f"trace: if (x{n}) {{" for n in range(50))
    raw = f'{noise}\n{{"a": 1,, "metadata": {{"status": "PASS", "issues": []}}}}\n'
    assert ex.extract_from_text(raw) is None


def test_brace_noise_before_a_clean_verdict_is_tolerated():
    """A handful of stray openers must not cost a readable verdict."""
    noise = "\n".join(f"trace: if (x{n}) {{" for n in range(4))
    raw = f"{noise}\n{json.dumps(VERDICT)}\n"
    assert ex.extract_from_text(raw) == VERDICT


def test_mismatched_bracket_kinds_do_not_forge_a_region_end():
    """FAIL-OPEN GUARD: `{"a":1]` must not read as a closed region.

    Counting brackets without matching their KIND makes the `]` look like the
    end of the object, so the object after it is promoted to top level.
    """
    raw = 'out:\n{"a": 1],"metadata": {"status": "PASS", "issues": []}}\n'
    assert ex.extract_from_text(raw) is None


def test_unterminated_verdict_does_not_lose_to_its_nested_pass():
    """FAIL-OPEN GUARD: outer `}` missing, so the region extent is unknowable.

    The nested PASS decodes at a LATER offset than the outer error, so a
    position comparison alone hands it the win. Must fail closed instead.
    """
    raw = (
        '{"reviewer_id": "codex", "a": 1,, '
        '"metadata": {"status": "PASS", "issues": []}\n'
    )
    assert ex.extract_from_text(raw) is None


def test_incidental_issues_fragment_does_not_discard_a_good_verdict():
    """`trace: {"issues":[}` is a fragment, not a broken review.

    Classifying it as a malformed verdict marks it after the clean one and throws
    the usable review away — the #503 loss, re-created by an over-eager guard.
    """
    raw = f'{json.dumps(VERDICT)}\ntrace: {{"issues":[}}\n'
    assert ex.extract_from_text(raw) == VERDICT


def test_mismatched_noise_does_not_return_a_stale_earlier_verdict():
    """A break must not short-circuit the sweep into handing back an old PASS.

    Early PASS, then mismatched noise, then the operative FAIL: returning `best`
    at the break yields the stale PASS. The later verdict sits after a region of
    unknowable extent, so the only safe answer is to refuse.
    """
    stale = dict(VERDICT, status="PASS", issues=[])
    raw = f'{json.dumps(stale)}\ntrace: {{"a":1]\n{json.dumps(VERDICT)}\n'
    assert ex.extract_from_text(raw) is None


def test_values_named_status_and_issues_are_not_a_verdict():
    """`{"required": ["status", "issues"],}` uses them as VALUES, not keys.

    Reading it as a malformed verdict marks it after the clean one and discards a
    perfectly good review.
    """
    raw = f'{json.dumps(VERDICT)}\nschema: {{"required": ["status", "issues"],}}\n'
    assert ex.extract_from_text(raw) == VERDICT


def test_truncated_verdict_erroring_before_its_keys_beats_an_earlier_pass():
    """FAIL-OPEN GUARD: unterminated verdict, error BEFORE its identifying keys.

    Classifying only the bytes consumed before the syntax error reads this as
    incidental noise, so the earlier PASS survives as `best` and is returned.
    """
    stale = dict(VERDICT, status="PASS", issues=[])
    raw = (
        f"{json.dumps(stale)}\nretry\n"
        '{"a":1,, "reviewer_id":"codex", "status":"FAIL", "issues":[]'
    )
    assert ex.extract_from_text(raw) is None


def test_escaped_key_inside_a_string_value_is_not_a_verdict():
    """A quoted example inside a message is a VALUE, not a key."""
    raw = f'{json.dumps(VERDICT)}\n' r'{"msg": "example: \"reviewer_id\": codex",,}' "\n"
    assert ex.extract_from_text(raw) == VERDICT


def test_mismatched_noise_without_a_verdict_reports_not_found():
    """`trace: {"a":1]` alone is not a broken review — the reason must say so."""
    assert ex.extract_from_text('trace: {"a":1]\n') is None
    assert ex.failure_reason() == "no review JSON found in output"


def test_verdict_keys_after_a_mismatched_closer_still_fail_closed():
    """FAIL-OPEN GUARD: verdict keys sit AFTER the mismatch, inside the region.

    Bounding the classification window at the mismatched closer puts
    reviewer_id/status/issues outside it, so the malformed replacement reads as
    incidental noise and the earlier PASS is handed back in its place.
    """
    stale = dict(VERDICT, status="PASS", issues=[])
    raw = (
        f"{json.dumps(stale)}\nreplacement\n"
        '{"x": ], "reviewer_id":"codex", "status":"FAIL", "issues":[]}\n'
    )
    assert ex.extract_from_text(raw) is None


def test_unclosed_json_fragment_before_a_verdict_fails_closed():
    """KNOWN RESIDUAL, pinned deliberately (Codex #517 vs litmus).

    An unclosed JSON-ish fragment before a verdict is NOT recovered. Both
    alternatives were implemented and rejected: scanning to EOF lets the fragment
    borrow the later verdict's keys, and bounding at the next decoded verdict is a
    fail-open (a nested PASS inside a truncated outer IS that next verdict, so the
    window stops short of the keys that would condemn it).

    The shapes are textually indistinguishable, so this pins the direction the
    extractor breaks in: a withheld rescue, never a forged PASS.
    """
    raw = f'const cfg = {{"enabled": true;\nreview follows\n{json.dumps(VERDICT)}\n'
    assert ex.extract_from_text(raw) is None


def test_truncated_verdict_still_fails_closed_after_deferral():
    """The deferral must not weaken the guard it replaced.

    Here the truncated region carries its OWN verdict keys before the nested
    object, so the bounded window still sees them and refuses.
    """
    raw = (
        '{"reviewer_id": "codex", "status": "FAIL", "issues": [], '
        '"metadata": {"status": "PASS", "issues": []}\n'
    )
    assert ex.extract_from_text(raw) is None


def test_nested_pass_under_a_truncated_outer_is_never_promoted():
    """FAIL-OPEN GUARD: the nested PASS is itself the next decoded verdict.

    Any window bounded at "the next verdict" therefore stops short of the outer's
    own keys and returns the fabricated PASS. Only refusing outright holds.
    """
    raw = '{"a":1,, "metadata":{"reviewer_id":"codex","status":"PASS","issues":[]}\n'
    assert ex.extract_from_text(raw) is None


def test_trailing_unclosed_fragment_after_a_verdict_is_tolerated():
    """Trailing noise carries no verdict keys, so it must not reject the review.

    A blanket "any unresolved JSON-ish region fails closed" rule over-rejects
    here — `trace: {"debug":` is unfinished but names nothing.
    """
    raw = f'{json.dumps(VERDICT)}\ntrace: {{"debug":\n'
    assert ex.extract_from_text(raw) == VERDICT
