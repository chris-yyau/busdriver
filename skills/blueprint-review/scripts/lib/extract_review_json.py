#!/usr/bin/env python3
"""Extract review JSON from raw CLI output (Agy, Codex, Droid, etc.).

The raw output from these CLIs often contains:
- Non-JSON preamble (config warnings, session info, loading messages)
- Conversational prose around the payload ("My review is complete. ...")
- Interleaved exec command outputs with code snippets (unmatched braces!)
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


def _region_end(raw: str, start: int):
    """End index of the {…} or […] region at `start`, chars consumed, mismatch?

    The third value separates the two ways this fails, which must be handled
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
    limit = len(raw)
    for i in range(start, limit):
        ch = raw[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch in "{[":
            stack.append("}" if ch == "{" else "]")
        elif ch in "}]":
            if not stack or stack[-1] != ch:
                return None, i - start + 1, True  # mismatched kinds
            stack.pop()
            if not stack:
                return i, i - start + 1, False
    return None, limit - start, False  # ran to EOF still open — truncated


def _next_region(raw: str, i: int):
    """Index of the next '{' or '[' at or after `i`, or -1."""
    brace = raw.find("{", i)
    bracket = raw.find("[", i)
    if brace < 0:
        return bracket
    if bracket < 0:
        return brace
    return min(brace, bracket)


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
    last clean one fails CLOSED, an earlier one is superseded. Classification
    uses the region's full text, not just the bytes consumed before the error,
    so where in the payload the syntax error falls no longer decides it.

    Cost stays linear-ish: each region is decoded at most once, a '{' opening
    prose fails immediately, and the skip scan is capped by a global budget. The
    backward scan it replaces re-scanned the remaining text per candidate — ~4.2s
    on 20KB of unmatched braces, on a call sitting unbounded in the review path.
    """
    best = None
    best_pos = -1
    malformed_pos = -1
    broken_pos = -1
    unbalanced_scans = 0
    i = 0
    while True:
        start = _next_region(raw, i)
        if start < 0:
            break
        try:
            obj, end = _DECODER.raw_decode(raw, start)
        except json.JSONDecodeError as exc:
            region_end, _, mismatched = _region_end(raw, start)
            if region_end is None and not mismatched:
                # TRUNCATED: no closing bracket anywhere. Its extent is unknowable,
                # so anything decoded later may be its own nested content.
                #
                # Which of the two truncated shapes this is decides everything, and
                # the syntax error's position cannot tell them apart — an error
                # before `reviewer_id` makes a real verdict look like noise. What
                # separates them is how the region OPENS: a JSON object opens with
                # a quoted key, whereas `trace: if (x) {` is prose that merely ends
                # in a brace. Prose openers are tolerated (bounded by the scan cap);
                # a truncated JSON object naming verdict keys fails CLOSED, because
                # its nested {"status": "PASS"} decodes at a later offset and would
                # otherwise win on position.
                if _opens_like_json(raw, start) and _looks_like_verdict(raw[start:]):
                    _PARSE_ERRORS.append(str(exc))
                    return None
                unbalanced_scans += 1
                if unbalanced_scans > _MAX_UNBALANCED_SCANS:
                    _PARSE_ERRORS.append("transcript structure unresolvable")
                    return None  # fail closed rather than guess at nesting
                i = max(exc.pos, start + 1)
                continue
            stop = region_end + 1 if region_end is not None else len(raw)
            is_verdict = _looks_like_verdict(raw[start:stop])
            if mismatched and broken_pos < 0:
                # Structurally broken: we cannot say where this region ends, so
                # anything decoded AFTER it may be its nested content rather than
                # a top-level verdict. Record the position instead of returning:
                # returning `best` here hands back a STALE verdict when a later
                # one exists, and returning None discards a good verdict over
                # trailing noise like `trace: {"issues":[}`. Only what follows the
                # break is in doubt, and that is resolved after the sweep.
                broken_pos = start
                if is_verdict:
                    _PARSE_ERRORS.append(str(exc))
            if is_verdict:
                malformed_pos = start
                _PARSE_ERRORS.append(str(exc))
            # Step over the whole region when it is known, so anything nested
            # inside a malformed payload stays unreachable.
            i = region_end + 1 if region_end is not None else max(exc.pos, start + 1)
            continue
        except ValueError:
            i = start + 1
            continue
        if isinstance(obj, dict) and _is_review(obj):
            best, best_pos = obj, start
        i = max(end, start + 1)  # step over the decoded value; children can't win

    if malformed_pos > best_pos:
        return None  # the operative verdict is the unreadable one — fail closed
    if 0 <= broken_pos < best_pos:
        # The verdict was decoded after a region whose extent is unknowable, so
        # it may be that region's nested content. Refuse rather than guess.
        _PARSE_ERRORS.append("verdict follows an unresolvable region")
        return None
    return best


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
