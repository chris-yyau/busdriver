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
