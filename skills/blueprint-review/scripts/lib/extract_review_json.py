#!/usr/bin/env python3
"""Extract review JSON from raw CLI output (Agy, Codex, Droid, etc.).

The raw output from these CLIs often contains:
- Non-JSON preamble (config warnings, session info, loading messages)
- Conversational prose around the payload ("My review is complete. ...")
- Interleaved exec command outputs with code snippets (unmatched braces!)
- A truncated one-line echo of the payload itself, e.g. codex's
  `[codex] Assistant message captured: { "status": "FAIL", … "issues": [ { "sect...`
- Token usage stats
- The actual review JSON — on one line, or pretty-printed inside a ```json fence

Extraction is ONE strategy: the last top-level JSON object that looks like a
review, located with json's own raw_decode. It covers every shape we have seen —
single-line, pretty-printed, and ```json-fenced (a fenced payload is just an
object with text around it) — so no fence strategy is needed.

The whole-file / line-scan / regex strategies that used to sit alongside it are
GONE, and deliberately so. They were position-blind, so whichever recognised a
shape first won regardless of where it sat in the transcript (an early fenced
PASS beat a later single-line FAIL). Worse, they were not inert as fallbacks: on
a malformed outer verdict the regex strategy matched the NESTED
{"status": "PASS", "issues": []} out of its metadata and returned it as the
verdict. A position-blind strategy cannot tell a verdict from a fragment, which
on this path means fabricating a PASS.

Usage:
  python3 extract_review_json.py <raw_file>   # from file
  echo "..." | python3 extract_review_json.py -   # from stdin
Prints extracted JSON to stdout. Exit 0 on success, 1 on failure. On failure a
single-line reason goes to stderr, so a caller can tell "never found the JSON"
apart from "found it and it was malformed" (#503: those looked identical in the
log for four review sessions).
"""

import json
import re
import sys
from dataclasses import dataclass

# Parse errors from candidate blocks that LOOKED like a review payload, kept for
# the failure message only.
# ponytail: module-level, so extract_from_text() is not reentrant — fine for a
# one-shot CLI; thread it as a parameter if this ever grows an in-process caller.
_PARSE_ERRORS: list[str] = []


def _is_review(obj) -> bool:
    """Does a parsed object look like a reviewer verdict?"""
    return isinstance(obj, dict) and (
        "reviewer_id" in obj or ("status" in obj and "issues" in obj)
    )


def _KEY_RE(name: str, text: str) -> bool:
    """Is `name` present as a JSON KEY (quoted, then a colon) in `text`?"""
    # The negative lookbehind keeps an ESCAPED quote from counting: a diagnostic
    # string like "example: \"reviewer_id\": codex" is a value, not a key, and
    # reading it as one discards the valid review that precedes it.
    return re.search(rf'(?<!\\)"{name}"\s*:', text) is not None


def _opens_like_json(raw: str, start: int) -> bool:
    """Does the region at `start` open the way a JSON container does?

    `{"reviewer_id": ...` opens with a quoted key; `trace: if (x) {` is prose that
    happens to end in a brace. Used only to tell a truncated PAYLOAD from
    incidental noise, where the syntax error's position cannot.
    """
    rest = raw[start + 1 : start + 64].lstrip()
    if not rest:
        return False
    return rest[0] == '"' if raw[start] == "{" else rest[0] in '"{['


def _line_end(raw: str, start: int) -> int:
    """Index of the newline ending `start`'s line, or len(raw) if it is the last.

    Single source for the echo's extent. Confinement, classification, and the
    skip-ahead all have to mean the SAME line — the classification window is only
    sound because it is the line the confinement test accepted, and the skip is
    only sound because it clears the line that was classified — so they share one
    definition rather than three copies that can drift apart.
    """
    end = raw.find("\n", start)
    return len(raw) if end < 0 else end


def _embedded_in_a_line(raw: str, start: int) -> bool:
    """Is there non-whitespace before `start` on its own line?

    A top-level payload begins its own line; `[codex] Assistant message captured:
    {…` does not. Leading whitespace still counts as line start, so an indented
    fenced payload is not disqualified.
    """
    return raw[raw.rfind("\n", 0, start) + 1 : start].strip() != ""


# Known CLI log framings that echo a TRUNCATED preview of the verdict into the
# transcript. Deliberately an allowlist of observed, fully-anchored phrasings —
# not a shape heuristic. See _is_log_echo_fragment for why nothing weaker is
# sound. Add a producer to the alternation only with a real transcript to
# justify it.
#
# The producer label is pinned, NOT a wildcard. A `[^\]]{1,32}` label would let
# any transcript line spell its own way past the allowlist — `[not-codex]
# Assistant message captured: {…` would be trusted as a CLI echo, the fragment
# skipped, and a PASS nested behind it promoted to the verdict. The framing is
# only evidence because the CLI is the sole thing that emits it, so who may
# write the label is the whole security property.
_LOG_ECHO_PREFIX_RE = re.compile(
    r"^\s*\[(?:codex)\]\s+Assistant message captured:\s*$"
)


# Known CLI log framings that echo A COMMAND, not a payload. Same pinned-producer
# discipline as _LOG_ECHO_PREFIX_RE, but a PREFIX match rather than an anchored
# one: arbitrary shell text follows, and the brace in question is inside it.
#
# All four phrasings are measured, not guessed. Across the 17 codex transcripts on
# hand, `Running command:` and `Command completed:` each echo the SAME command
# text — the second is not a result line — and each hosts ~39 undecodable regions.
# #554 named only the first, which is why the fix aimed at it did not rescue the
# reported artifact: there the poisoning brace at byte 1746 sits on the
# `Command completed:` twin of the line at 1622. `Command failed:` is the same
# echo on the error path. `Searching:` hosted no region in the sample and is
# included on shape: it echoes a search PATTERN, and the brace-carrying command
# #554 opens with is a regex quantifier (`rg -n '"'^#{1,4...`).
#
# `Assistant message captured:` is deliberately NOT here. That line can carry the
# verdict itself, so it needs _skip_log_echo's bookkeeping (record malformed_pos,
# set own_line_only), not a silent skip — see _is_log_echo_fragment and #527.
#
# No `^` anchor: this is applied with `Pattern.match(raw, line_start, start)`,
# which anchors at `pos` itself. A `^` would additionally demand position 0 and so
# match only on the transcript's first line.
#
# No leading `\s*` either, unlike `_LOG_ECHO_PREFIX_RE` — deliberately, and for a
# performance reason that is really a correctness one (codex, PR review round 2).
# This runs at EVERY candidate region, so on a deeply indented line `\s*` rescans
# the whole indent per region: 64,000 `{}` regions behind a 4,000-space indent cost
# 2052ms with it against 1422ms without. Measured on the transcripts on hand, 0 of
# 694 framing lines carry any indentation — codex emits them at column 0 — so the
# tolerance bought nothing. An indented framing simply is not recognized and the
# sweep reverts to its pre-#554 behavior, which fails closed.
_LOG_PROGRESS_PREFIX_RE = re.compile(
    r"\[(?:codex)\]\s+"
    r"(?:Running command|Command completed|Command failed|Searching):\s"
)

# JSON allows any key character to arrive as a `\uXXXX` escape, so `"status"`
# is the key `status` and a raw-text search for `"status"` misses it (codex, review
# of this change). Decoded before the supersede check below — see _unescaped_line.
_UNICODE_ESCAPE_RE = re.compile(r"\\u([0-9a-fA-F]{4})")


def _is_progress_line(raw: str, line_start: int, start: int) -> bool:
    """Is `start` inside a CLI progress line, where no JSON region can exist?

    Codex echoes each command before running it, cut to a display limit:

        [codex] Running command: /bin/zsh -lc "rg -n \\"import \\{ en \\}|Locale p...

    That brace belongs to the COMMAND. raw_decode anchors on it, cannot find where
    the value ends because the line was cut, and the region is recorded as
    unresolvable — after which `_resolve` refuses the complete verdict printed
    below it (#554: verdict at byte 5426, first unresolvable region at byte 1622).

    **Chronic, not incidental.** The poisoning brace came from grepping for
    `import { en }`. Any review whose transcript echoes a command containing a
    brace and is then truncated is discarded, whatever the verdict says — and
    which commands codex runs varies per round, so the same document passes and
    fails on consecutive rounds. One plan ran seven blueprint-review rounds and
    never issued a PASS.

    **Why recognition sits here and not in either resolver.** The two reported
    runs died in different branches — `_resolve`'s `broken_pos < best_pos` check,
    and `_handle_truncated`'s open-like-JSON test — from the same upstream cause.
    Patching either leaves the other failing, so the line is declined as a
    candidate region before `raw_decode` ever sees it.

    **This direction is a rejection, not a rescue, and that inverts the threat
    model of `_is_log_echo_fragment`.** There, recognizing the framing ADMITS a
    verdict that would otherwise be refused, so a forged producer label buys real
    power and the pin is the security property. Here it only removes a candidate.
    A region skipped can never become the verdict, so no framing — forged or
    genuine — can promote anything. The pin is kept because an unpinned phrasing
    is not evidence codex emitted the line, and a reviewed document could then
    suppress a real verdict by quoting the framing on the verdict's own line.

    Skipping is also strictly SAFER than the status quo on the decoded path. An
    echoed command may quote a complete review-shaped object — codex greps the
    document under review, so the literal can come from the artifact itself — and
    today that object decodes cleanly and last-verdict-wins promotes it over the
    real FAIL above. Pinned regression test:
    `test_a_verdict_shaped_object_inside_a_progress_line_is_never_the_verdict`.

    ACCEPTED RESIDUAL — a forged framing can now buy ACCEPTANCE where the sweep
    used to refuse, and no narrower rule removes it (codex, PR review). Reviewed
    content reaches the transcript (codex prints command OUTPUT too), so a line
    beginning `[codex] Running command: {` can be forged. Pre-#554 that unresolved
    region set `broken_pos` and everything after it was refused; now it is skipped,
    so a later own-line PASS is accepted.

    This is UNFIXABLE without reinstating #554, because the two requirements are in
    direct conflict and differ only in a fact the text cannot carry:

        #554  a verdict after an unresolvable command-echo region must be ACCEPTED
        forge a verdict after an unresolvable command-echo region must be REFUSED

    What bounds it: the skip can only ever REMOVE a candidate, so no forged framing
    promotes anything by itself — the attacker must already be able to place an
    own-line review object in the transcript, and such an object wins on
    last-verdict-wins with or without the forgery. The gain is narrow: it lets them
    emit unresolvable junk beforehand without that junk defeating their own forgery.
    Refusing instead would restore precisely the chronic DEGRADED-coverage failure
    this path exists to remove. `malformed_pos` was measured as a middle road and
    does not help — a later verdict outranks it by design, which is the point.
    Note also that `_looks_like_verdict` below still fires on a skipped line
    carrying verdict keys, so the forgery cannot both hide and be verdict-shaped.

    KNOWN RESIDUAL: a command echo that spans lines (a heredoc, say) is recognized
    only on its first line; a brace on a continuation line still poisons the sweep.
    Measured: ZERO multi-line echoes across the 17 transcripts on hand — codex
    truncates each echo to one line with `...`, which is what makes single-line
    recognition complete in practice. Behavior on a continuation line is UNCHANGED
    by this path, so it is a pre-existing limit, not a regression introduced here.

    `line_start` is SUPPLIED by the sweep, not recomputed here, and matching uses
    `pos`/`endpos` against `raw` rather than a slice — the pattern carries no `^`
    because `Pattern.match` anchors at `pos` on its own. Both avoid per-region work
    proportional to the distance back to the line start, which is what makes one
    long line quadratic: a slice copies a growing prefix, and `rfind("\\n", 0,
    start)` scans a growing span backwards. Measured on 64,000 `{}` regions sharing
    one line, this recognizer costs 1.8ms supplied against ~1000ms recomputed
    (codex, review of this change).
    """
    return _LOG_PROGRESS_PREFIX_RE.match(raw, line_start, start) is not None


def _unescape(text: str) -> str:
    """`\\uXXXX` decoded, then remaining backslashes dropped. ORDER MATTERS.

    Dropping backslashes first would turn `\\u0061` into the literal `u0061` and
    lose the escape, so the Unicode pass runs first. `chr()` on a lone surrogate is
    fine in a Python str, and this text is only ever pattern-matched, never
    decoded as JSON, so an unpaired surrogate cannot raise here.
    """
    return _UNICODE_ESCAPE_RE.sub(lambda m: chr(int(m.group(1), 16)), text).replace(
        "\\", ""
    )


def _unescaped_line(raw: str, start: int, end: int) -> str:
    """The WHOLE line holding `start`, up to `end`, with escapes normalized.

    Feeds the supersede check on the command-echo path, and both transforms matter
    there (codex, review of this change).

    Backslashes go because `_KEY_RE`'s `(?<!\\\\)` lookbehind is calibrated for the
    OPPOSITE direction of risk. On its usual paths an escaped `\\"status\\":` really
    is a value inside a string, and reading it as a key discards a good review — so
    it must not match. Here a match only ever raises `malformed_pos`, which can
    withhold a verdict but can never promote one, so under-matching is the harmful
    error. A shell echo quotes its command, so the keys arrive escaped
    (`echo {\\"status\\":\\"FAIL\\"}`) and the lookbehind skipped them, leaving a
    stale earlier PASS standing — a direct variant of the bug this path exists to
    close.

    Normalizing rather than loosening the KEY SHAPE is the whole design. A weaker
    test — bare `status` as a substring — would fire on `rg -n 'issues' docs/` and
    withhold a perfectly good review, which is the DEGRADED-coverage failure #554
    is about. Over-firing is not free here; it is just cheaper than under-firing.

    The window is the whole line, not `raw[start:]`, because the region found first
    can sit AFTER the keys: in `rg -n '\"status\":\"PASS\",\"issues\":[]'` the first
    bracket is the `[` of `[]`, so a window opening there sees no keys at all.
    Bounded by one line and reached only once per skipped line (the sweep resumes
    past the line end), so the copy here cannot become the quadratic that
    `_is_progress_line` had to avoid.
    """
    return _unescape(raw[raw.rfind("\n", 0, start) + 1 : end])


def _is_log_echo_fragment(raw: str, start: int) -> bool:
    """Is this unclosed region a known CLI log echo rather than a real payload?

    Codex streams a ~100-char preview of its own verdict into the log:

        [codex] Assistant message captured: { "status": "FAIL", … "issues": [ { "sect...

    By shape that is indistinguishable from a verdict, so region detection anchors
    on it, sweeps forward past the intervening log lines looking for a close it
    will never find, and fails closed — discarding the complete verdict printed
    below it (#524).

    Identification is the LOG FRAMING and nothing else, positively matched against
    `_LOG_ECHO_PREFIX_RE`. An untruncated payload after the same prefix decodes
    fine and never reaches here, so arriving here with the framing present means
    codex emitted a preview it could not finish.

    **The decoder's stopping point is not consulted, and must not be** (#529).
    Three shapes were reported where a cross-check on `exc.pos` misfired, and they
    have one root cause: `exc.pos` is not a proxy for "did this region extend past
    its line." raw_decode stops wherever it stops, and after an incomplete opening
    token it will happily consume valid next-line JSON first:

        [codex] Assistant message captured: {"status":"FAIL","issues":[
        { …the real verdict… }

    Measured on the reported transcript: the decode ran 143 characters past the
    line's end, with the entire real verdict inside the intervening slice. Any
    "did content intervene" test therefore reads the REAL VERDICT as proof the
    echo was not an echo, rejects the allowlisted framing, and discards the review
    — #524 reinstated at a different cut point. Every attempt to fix one variant
    by moving the window boundary broke another (`342dec8` closed one and opened
    another; reverted in `e7e28a0`).

    The framing alone is the whole identification, and it is complete: the echo's
    extent IS its line, by construction, because that is how the producer emits
    it. Re-deriving that from where the decoder happened to stop can only LOSE the
    fact, never establish it. (Same argument `db6386d` used to drop the
    verdict-shape sniff on this path.)

    **What the dropped cross-check was worth: nothing.** Its only claimed value was
    keeping a genuinely broken MULTI-LINE payload from being read as an echo, so
    its nested PASS stayed unreachable. It never did that — it caught the hazard
    only when the decoder happened to stop past the line. The identical hazard cut
    one character earlier (a raw newline inside a string, so the decode dies ON the
    line) was recognized as an echo and its nested PASS promoted, on `main`, before
    this change. Measured both ways before removing it. The guard that actually
    holds this line is `_LOG_ECHO_PREFIX_RE`.

    **Why nothing weaker than the pinned framing is sound.** The first fix here
    inferred "log echo" from geometry alone — starts mid-line AND died on a newline
    — reasoning that a raw newline inside a string proves the region cannot extend
    past that line. That reasoning is wrong, and two independent reviewers caught
    it. A newline breaks the region as *valid JSON*, but the following text is
    still lexically inside the unclosed braces, so it may be the region's CHILD.
    Confirmed:

        log: {"status":"FAIL","issues":["x
        {"status":"PASS","issues":[]}

    A genuine mid-line FAIL, broken by a stray newline, was read as noise and its
    nested PASS promoted to the verdict — the exact forged PASS #503 hardened
    against. Geometry cannot separate "noise then a verdict" from "a broken
    verdict wrapping a nested one"; only positive recognition of the log framing
    can, because only the CLI emits it.

    The allowlist is brittle by design. If codex changes its wording this stops
    matching and the extractor reverts to failing closed (a withheld rescue, the
    pre-#524 behavior) — never to accepting a forged PASS. That is the correct
    direction to break in.
    """
    line_start = raw.rfind("\n", 0, start) + 1
    return _LOG_ECHO_PREFIX_RE.match(raw[line_start:start]) is not None


def _looks_like_verdict(text: str) -> bool:
    """Was this malformed region evidently MEANT to be a verdict?

    Mirrors _is_review's shape rather than matching any single key, and matches
    them as KEYS (followed by a colon) rather than as words appearing anywhere.
    Both narrowings exist to avoid discarding a good review: neither word alone
    is sufficient, since interleaved diagnostics carry `config = {"status":
    pending}` constantly and a truncated `trace: {"issues":[}` is a fragment; and
    a substring test misreads a snippet like {"required": ["status", "issues"]},
    where the words are VALUES, as a broken verdict.
    """
    if _KEY_RE("reviewer_id", text):
        return True
    return _KEY_RE("status", text) and _KEY_RE("issues", text)

# How many UNBALANCED regions the skip scan may chase before giving up. Only
# unbalanced regions are expensive: a balanced one stops at its own closing
# bracket, while an unbalanced one runs to EOF, so a transcript of nothing but
# stray '{' would be quadratic without a cap.
#
# The cap must never translate into "advance into the region instead" — that was
# a silent fail-open: roughly two stray braces in a preamble exhausted a
# character budget, after which a malformed outer verdict was stepped INTO and
# its nested {"status": "PASS"} extracted as the verdict. Short test fixtures
# never reached the cap, so the suite could not see it. Exhausting the cap now
# fails CLOSED instead. The limit is set well above realistic noise — droid folds
# stderr into the same file, so a few stray brackets are normal — but far below
# the pathological case, bounding worst-case work at 64 scans of the transcript.
_MAX_UNBALANCED_SCANS = 64

_DECODER = json.JSONDecoder()


def _advance_string(ch: str, esc: bool):
    """Next (still_in_string, escaped) after `ch` while inside a JSON string.

    Split out of _region_end purely to keep that scan under the complexity
    threshold (#518); the escape rule is unchanged — a backslash arms the next
    character, an armed character never closes the string.
    """
    if esc:
        return True, False
    if ch == "\\":
        return True, True
    return ch != '"', False


def _apply_bracket(stack: list, ch: str) -> bool:
    """Push or pop `ch` on `stack`; True if it closed the wrong KIND.

    Split out of _region_end for the complexity budget (#518). Bracket kinds are
    matched, not merely counted: a shared depth counter treats `{"a": 1]` as a
    closed region, and the nested object after it then reads as top-level — a
    fabricated PASS.
    """
    if ch in "{[":
        stack.append("}" if ch == "{" else "]")
        return False
    return not stack or stack.pop() != ch


def _region_end(raw: str, start: int):
    """End index of the {…} or […] region at `start`, and whether it MISMATCHED.

    Returns (int|None, bool). Deliberately UNANNOTATED: a `tuple[int | None,
    bool]` return annotation is evaluated at import time and raises TypeError on
    Python 3.9 (PEP 604 landed in 3.10), and this module is invoked through an
    unversioned `python3`. Annotating it would make the extractor die before
    reading a single review on any 3.9 install.

    The second value separates the two ways this fails, which must be handled
    differently. TRUNCATED (ran to EOF still open) is what a stray `{` in prose
    looks like, and is tolerated — treating it as fatal would discard a good
    verdict for incidental noise. MISMATCHED (a `]` closing a `{`) means the
    region is structurally broken, and anything decoded after it may be its
    nested content rather than a top-level verdict.

    String-aware, so brackets quoted inside JSON strings do not count. Bracket
    KINDS are matched, not merely counted: a shared depth counter treats
    {"a": 1] as a closed region, and the nested object after it then reads as
    top-level — a fabricated PASS.

    Used solely to skip a region that failed to decode — never to extract — so a
    desync caused by an odd quote in surrounding prose costs a skip, not a wrong
    verdict.
    """
    stack = []
    in_str = False
    esc = False
    for i in range(start, len(raw)):
        ch = raw[i]
        if in_str:
            in_str, esc = _advance_string(ch, esc)
        elif ch == '"':
            in_str = True
        elif ch in "{[}]":
            if _apply_bracket(stack, ch):
                return None, True  # mismatched kinds
            if not stack:
                return i, False  # a push never empties the stack, so this is a close
    return None, False  # ran to EOF still open — truncated


def _next_region(raw: str, i: int) -> int:
    """Index of the next '{' or '[' at or after `i`, or -1."""
    brace = raw.find("{", i)
    bracket = raw.find("[", i)
    if brace < 0:
        return bracket
    if bracket < 0:
        return brace
    return min(brace, bracket)


@dataclass
class _Sweep:
    """Mutable state threaded through one forward sweep of a transcript.

    A plain record, not an abstraction. The sweep's branches were extracted into
    helpers to bring `try_last_review_object` back under the complexity threshold
    (#518, CCN 23 vs 9), and every one of those helpers updates the same handful
    of positions — one shared record beats five in/out parameters per call.
    """

    raw: str
    best: object = None
    best_pos: int = -1
    malformed_pos: int = -1
    broken_pos: int = -1
    unbalanced_scans: int = 0
    own_line_only: bool = False
    # Line cursor, advanced FORWARD by `_seek_line` as the sweep moves. Regions are
    # visited in increasing position, so tracking the current line costs one pass
    # over the transcript in total — where recomputing `rfind("\n", 0, start)` per
    # region costs a backward scan each time, which is quadratic on a long line.
    line_start: int = 0
    next_newline: int = -2  # -2 = not primed; -1 = no newline left


def _seek_line(st: "_Sweep", start: int) -> int:
    """Line start for `start`, advancing the cursor. Regions must arrive in order.

    Invariant, asserted in the tests against every real transcript on hand: the
    value returned always equals `raw.rfind("\\n", 0, start) + 1`.
    """
    if st.next_newline == -2:
        st.next_newline = st.raw.find("\n")
    while st.next_newline != -1 and st.next_newline < start:
        st.line_start = st.next_newline + 1
        st.next_newline = st.raw.find("\n", st.line_start)
    return st.line_start


def _skip_log_echo(st: "_Sweep", start: int, exc: json.JSONDecodeError) -> int:
    """Record a recognized CLI log echo (#524) and step past its whole line."""
    # Recorded UNCONDITIONALLY — no verdict-shape sniff at all. Widening the
    # window from exc.pos to the whole line closed the case cubic reported, but
    # not the class: the preview is cut to a fixed length, so a short one carries
    # NO verdict key to find (`[codex] Assistant message captured: {`), sniffs as
    # not-a-verdict, leaves malformed_pos unset, and hands back an earlier
    # superseded PASS. The sniff was never load-bearing here —
    # `_LOG_ECHO_PREFIX_RE` has already positively identified this line as codex
    # echoing its OWN verdict, so a verdict demonstrably existed. Re-deriving that
    # fact from the truncated preview's keys can only LOSE it, never establish it.
    # If the real verdict is found below, best_pos outranks this and the echo
    # costs nothing; if it is not, refusing is correct.
    st.malformed_pos = start
    _PARSE_ERRORS.append(str(exc))
    # Defense in depth behind the allowlist: past a skipped region, a MID-LINE
    # object could still be some other region's child, so from here only own-line
    # objects can win. See _handle_decoded for why #527 does not relax this.
    st.own_line_only = True
    # Skip the WHOLE classified line, not just to exc.pos. The echo's extent was
    # established as its line, and exc.pos is only where the decode happened to
    # die — for a cut between tokens, later `[`/`{` on that same line sit beyond
    # it. Resuming at exc.pos re-entered the very fragment just ruled a
    # non-payload, took one of those brackets as a fresh unresolved region, and
    # let it borrow the real verdict's keys: `{ "status": ... "issues": [ { "sect`
    # above a complete verdict returned None. The #524 loss again, one path
    # further in.
    return max(_line_end(st.raw, start), start + 1)


def _handle_truncated(st: "_Sweep", start: int, exc: json.JSONDecodeError):
    """A region with no closing bracket anywhere. Next index, or None to refuse.

    Its extent is unknowable, so anything decoded later may be its own nested
    content.

    Which of the two truncated shapes this is decides everything, and the syntax
    error's position cannot tell them apart — an error before `reviewer_id` makes
    a real verdict look like noise. Two signals separate them, and BOTH are
    needed:

    1. How the region OPENS. A JSON object opens with a quoted key, whereas
       `trace: if (x) {` is prose that merely ends in a brace.
    2. Whether verdict keys appear before the NEXT complete verdict. Testing
       raw[start:] instead — the whole remaining transcript — lets an unclosed
       code fragment like `const cfg = {"enabled": true;` borrow the keys of a
       later, unrelated verdict and fail closed on it, discarding a perfectly
       readable review. That is the #503 loss re-created, on exactly the
       interleaved-code input this module's docstring calls routine.

    The window is the whole remaining transcript, and every attempt to narrow it
    has been worse:

      - Bounding at the next decoded verdict is a FAIL-OPEN. In
        `{"a":1,, "metadata":{"reviewer_id":..,"status":"PASS"}}` the nested PASS
        IS that next verdict, so the window stops short of the keys that would
        have condemned it.
      - Rejecting on ANY unresolved JSON-ish region over-rejects: a complete
        verdict followed by trailing `trace: {"debug":` is perfectly readable, and
        the trailing fragment carries no verdict keys, so scanning to EOF already
        tolerates it.

    KNOWN RESIDUAL: a fragment that opens like JSON, never closes, and PRECEDES
    the verdict (`const cfg = {"enabled": true;`) does borrow the verdict's keys
    and fails closed on a readable review. "Noise then a verdict" and "a truncated
    verdict wrapping a nested one" are textually indistinguishable, so this
    refuses rather than guess: a withheld rescue, never a forged PASS.
    """
    if _opens_like_json(st.raw, start) and _looks_like_verdict(st.raw[start:]):
        _PARSE_ERRORS.append(str(exc))
        return None
    st.unbalanced_scans += 1
    if st.unbalanced_scans > _MAX_UNBALANCED_SCANS:
        _PARSE_ERRORS.append("transcript structure unresolvable")
        return None  # fail closed rather than guess at nesting
    return max(exc.pos, start + 1)


def _record_broken_region(
    st: "_Sweep", start: int, exc: json.JSONDecodeError, region
) -> int:
    """Note a malformed region whose extent IS known, and step over it."""
    # Classification window. A resolved region is bounded by its own end; an
    # UNRESOLVED one is scanned to EOF.
    #
    # Narrowing the unresolved window to the bytes _region_end consumed looks
    # tidier — it keeps the recorded REASON from picking up keys that belong to a
    # later verdict — but it is a fail-open, so the tidiness is not available.
    # Scanning stops at the mismatched closer, so in
    # `{"x": ], "reviewer_id":"codex", "status":"FAIL", "issues":[]}` the verdict
    # keys fall OUTSIDE the window, is_verdict reads false, malformed_pos is never
    # set, and an earlier PASS is returned in place of this malformed FAIL.
    # Diagnostic precision is not worth a forged verdict; the window stays wide,
    # and being wide only ever costs a fail-CLOSED refusal.
    region_end, mismatched = region
    stop = len(st.raw) if region_end is None else region_end + 1
    if mismatched and st.broken_pos < 0:
        # Structurally broken: we cannot say where this region ends, so anything
        # decoded AFTER it may be its nested content rather than a top-level
        # verdict. Record the position instead of returning: returning `best` here
        # hands back a STALE verdict when a later one exists, and returning None
        # discards a good verdict over trailing noise like `trace: {"issues":[}`.
        # Only what follows the break is in doubt, and that is resolved after the
        # sweep.
        st.broken_pos = start
    if _looks_like_verdict(st.raw[start:stop]):
        st.malformed_pos = start
        _PARSE_ERRORS.append(str(exc))
    # Step over the whole region when it is known, so anything nested inside a
    # malformed payload stays unreachable.
    return max(exc.pos, start + 1) if region_end is None else region_end + 1


def _handle_malformed(st: "_Sweep", start: int, exc: json.JSONDecodeError):
    """Route a region that failed to decode. Next index, or None to refuse."""
    if _is_log_echo_fragment(st.raw, start):
        # A recognized CLI log echo (#524) — not a payload at all. Classify it on
        # its own line; scanning to EOF would let it borrow the real verdict's
        # keys, which is how it came to outrank one.
        #
        # Checked BEFORE _region_end, not gated behind its result (Codex, PR
        # #525). _region_end scans the WHOLE remaining transcript looking for a
        # close, so when the real verdict below contains a `]` or an escaped quote
        # that desyncs the bracket stack, it can report `mismatched=True` for a
        # region whose OWN line is an unambiguous, positively-framed echo. Gating
        # recognition on that scan's outcome let unrelated content deep in the
        # real verdict silently disable the allowlist, discarding the very review
        # #524 exists to keep. The pinned framing already fully proves the
        # classification; nothing downstream can un-prove it.
        return _skip_log_echo(st, start, exc)
    region = _region_end(st.raw, start)
    region_end, mismatched = region
    if region_end is None and not mismatched:
        return _handle_truncated(st, start, exc)
    return _record_broken_region(st, start, exc, region)


def _handle_decoded(st: "_Sweep", start: int, obj, end: int) -> int:
    """Consider a cleanly decoded value as the verdict, and step over it."""
    # NOT RELAXED FOR #527, deliberately. Codex reports that its real shape puts
    # the verdict behind prose on one line — `Final answer: {…}` — which
    # own_line_only discards, losing the review. Every rule that accepts it is
    # POSITIONAL ("the first payload after the echo is the one it previewed"),
    # because the prose is arbitrary; and a positional rule cannot authenticate
    # the object it admits, so `wrapper: {"status":"PASS",…}` in that slot is
    # admitted on identical evidence. Measured: the first-payload form returns
    # that PASS. A phrase allowlist would need a real transcript pinning the
    # wording, and none is in hand — #527 records exactly this. Withholding a
    # review is the correct direction to break in; fabricating a PASS is not.
    embedded = _embedded_in_a_line(st.raw, start)
    if not (isinstance(obj, dict) and _is_review(obj)):
        return max(end, start + 1)
    if not (st.own_line_only and embedded):
        st.best, st.best_pos = obj, start
    if not embedded:
        # An own-line REVIEW resynced the sweep to top level, so the skipped echo
        # can no longer be parenting what follows.
        #
        # It must be a REVIEW, not merely any decodable own-line value. An
        # unclosed echo swallows everything after it lexically, and
        # _embedded_in_a_line only inspects the physical line — so a
        # pretty-printed child starting at column 0 is "own-line" while still
        # nested. An arbitrary log value is therefore not proof the echo ended;
        # clearing on one let `wrapper: {"status":"PASS"}` be promoted from inside
        # it. A verdict-shaped own-line object is the narrowest thing that does
        # carry the proof.
        #
        # Without this reset own_line_only stayed set for the rest of the
        # transcript, so every later prefixed verdict was silently dropped: echo,
        # then an own-line PASS, then `Final answer: {…"status":"FAIL"…}` returned
        # the stale PASS. That breaks last-verdict-wins in the dangerous direction
        # — promoting a PASS over a later FAIL is the fabricated-PASS failure #503
        # hardened against.
        st.own_line_only = False
    return max(end, start + 1)  # step over the decoded value; children can't win


def _resolve(st: "_Sweep"):
    """The operative verdict at the end of a sweep, or None."""
    if st.malformed_pos > st.best_pos:
        return None  # the operative verdict is the unreadable one — fail closed
    if 0 <= st.broken_pos < st.best_pos:
        # The verdict was decoded after a region whose extent is unknowable, so it
        # may be that region's nested content. Refuse rather than guess.
        _PARSE_ERRORS.append("verdict follows an unresolvable region")
        return None
    return st.best


def _handle_progress_line(st: "_Sweep", raw: str, start: int) -> int:
    """Step over an echoed shell-command line that only LOOKS like a JSON
    region — a brace inside `[codex] Running command: {...}` (#554).

    Declined before raw_decode, so it can neither be recorded as unresolvable
    nor decoded into a verdict. Step over the whole line: the echo's extent
    IS its line, by construction.

    `own_line_only` is deliberately NOT set here, unlike `_skip_log_echo`.
    That flag guards against a LEXICAL parent — a truncated JSON payload
    whose unclosed braces swallow what follows. A shell command echo is
    not JSON, so there is nothing for a later object to be a child of, and
    setting the flag would discard prefixed verdicts for no gain.

    But a skipped line that CARRIES VERDICT KEYS must still supersede an
    earlier verdict, exactly as `_skip_log_echo` does (codex, review of
    this change). Without this, `{"status":"PASS"}` own-line followed by a
    command echo quoting a verdict hands back the PASS — a stale PASS
    standing in for something later, the #503 direction.

    The two readings of that shape are textually indistinguishable: an
    echo quoting a FORGED PASS after a real FAIL, and an echo quoting a
    real one after a stale PASS. Neither can be authenticated, so this
    refuses instead of guessing — a withheld review, never a fabricated
    verdict.
    """
    i = max(_line_end(raw, start), start + 1)
    if _looks_like_verdict(_unescaped_line(raw, start, i)):
        st.malformed_pos = start
        _PARSE_ERRORS.append("verdict keys inside a CLI command echo")
    return i


def try_last_review_object(raw: str):
    """Last TOP-LEVEL object in the transcript that looks like a review.

    Sweeps forward, decoding at each '{' with json's own raw_decode. That is the
    point: raw_decode already knows where a JSON value ends, honouring string
    literals and backslash escapes, so no brace counting is involved. The
    hand-rolled matcher this replaces counted braces without string context, so
    any review whose prose quoted code — most of them; one sampled artifact held
    65 braces inside issue descriptions — never balanced at the true object
    boundary (#503).

    Sweeping FORWARD and stepping over every region — decoded or not — is what
    keeps a NESTED object from being mistaken for the verdict. A backward scan
    reaches the innermost object first, so a root FAIL whose metadata ends with
    {"status": "PASS", "issues": []} extracts as that nested PASS, which the
    rescue then retags and accepts. Stepping over a decoded object closes that;
    stepping over a FAILED region closes it on the error path too, where a single
    trailing comma in the outer verdict would otherwise expose the same nested
    PASS one character later.

    Arrays are regions too, not just objects. Sweeping only for '{' starts
    decoding INSIDE a `[{...}]` wrapper and returns the element as though it were
    the top-level verdict. Both bracket kinds are therefore stepped over, and a
    decoded value that is not a dict never becomes a verdict.

    Malformed regions are tracked by POSITION rather than acted on immediately,
    because both shortcuts fail. Returning as soon as one is seen means a later
    corrected verdict is never examined; ignoring one because its syntax error
    happens to precede reviewer_id leaves an earlier stale PASS standing in for
    it. So the sweep runs to the end and compares: a malformed verdict AFTER the
    last clean one fails CLOSED, an earlier one is superseded. Classification uses
    the region's full text, not just the bytes consumed before the error, so where
    in the payload the syntax error falls no longer decides it.

    Cost stays linear-ish: each region is decoded at most once, a '{' opening
    prose fails immediately, and the skip scan is capped by a global budget. The
    backward scan it replaces re-scanned the remaining text per candidate — ~4.2s
    on 20KB of unmatched braces, on a call sitting unbounded in the review path.

    The per-branch reasoning lives on the helpers this delegates to; each one
    encodes a specific adversarial case with a pinned regression test.
    """
    st = _Sweep(raw)
    i = 0
    while True:
        start = _next_region(raw, i)
        if start < 0:
            break
        if _is_progress_line(raw, _seek_line(st, start), start):
            # Not a JSON region at all — see _handle_progress_line for why this
            # is stepped over rather than decoded, and why a verdict-shaped echo
            # still supersedes an earlier verdict.
            i = _handle_progress_line(st, raw, start)
            continue
        try:
            obj, end = _DECODER.raw_decode(raw, start)
        except json.JSONDecodeError as exc:
            nxt = _handle_malformed(st, start, exc)
            if nxt is None:
                return None
            i = nxt
            continue
        except ValueError:
            i = start + 1
            continue
        i = _handle_decoded(st, start, obj, end)

    return _resolve(st)


def extract_from_text(raw: str):
    """Extract the operative verdict, or None."""
    _PARSE_ERRORS.clear()
    return try_last_review_object(raw)


def failure_reason() -> str:
    """One-line explanation of why the last extract_from_text() found nothing."""
    if _PARSE_ERRORS:
        # The LAST malformed region is the operative one, matching extraction.
        return f"found a review block but it is malformed: {_PARSE_ERRORS[-1]}"
    return "no review JSON found in output"


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
        print(failure_reason(), file=sys.stderr)
        sys.exit(1)
