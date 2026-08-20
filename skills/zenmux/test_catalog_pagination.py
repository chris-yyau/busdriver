"""Guard for the catalog-discovery snippet embedded in skills/zenmux/SKILL.md.

The snippet is what an agent actually runs, so the test EXTRACTS it from the
document and executes it rather than re-implementing the logic. A copy would
drift from the doc silently — which is the failure this file exists to prevent.

What is guarded, and why each case has a real failure mode:

  1. `has_more` with no usable cursor, and the page cap, both mean the catalog
     was read PARTIALLY. Neither may count toward `fully read N/3`, because the
     whole point of the skill is that a short read must never be reported as a
     complete one ("absence is not evidence of absence").
  2. A `has_more` that repeats the same cursor never advances — without a seen-set
     the loop refetches the identical page up to the cap, inflating modality
     counts and stalling discovery.
  3. A schema change (list -> dict) or a dead endpoint must drop that catalog,
     not abort the others.
  4. Every catalog failing must exit NON-ZERO. Exiting 0 with an empty result is
     indistinguishable from "ZenMux does not offer this".
"""

import io
import json
import pathlib
import sys
import urllib.request

import pytest

SKILL = pathlib.Path(__file__).with_name("SKILL.md")


def _snippet() -> str:
    """Pull the python body out of the first ```bash fence in SKILL.md."""
    lines = SKILL.read_text(encoding="utf-8").splitlines()
    start = next(i for i, ln in enumerate(lines) if ln.strip() == "```bash")
    end = next(i for i in range(start + 1, len(lines)) if lines[i].strip() == "```")
    body = lines[start + 1 : end]
    body = [ln for ln in body if not ln.startswith("python3 - ") and ln.strip() != "PY"]
    src = "\n".join(body)
    assert "CATALOGS" in src, "snippet extraction missed the catalog loop"
    return src


def _exec_snippet(fake_urlopen, argv):
    """Swap urlopen/stdout/stderr/argv, exec the SKILL.md snippet, restore.

    Shared by every test that runs the snippet, so the swap/restore dance and
    the SystemExit-to-code conversion live in exactly one place — this file's
    own stated purpose is to prevent drift, and three copies of this harness
    would be exactly that kind of drift-prone repetition.
    """
    real_urlopen, real_argv = urllib.request.urlopen, sys.argv
    out, err = io.StringIO(), io.StringIO()
    real_stdout, real_stderr = sys.stdout, sys.stderr
    code = 0
    try:
        urllib.request.urlopen = fake_urlopen
        sys.argv = argv
        sys.stdout, sys.stderr = out, err
        # Executing the snippet is the POINT: a re-implementation here would
        # drift from the doc and guard nothing. The input is not external — it
        # is a fixed code fence in a checked-in file next to this test, read
        # from `__file__`'s own directory, and `_snippet()` asserts on its
        # content. Anyone who can change it can already change this test.
        # nosemgrep: python.lang.security.audit.exec-detected.exec-detected
        exec(compile(_snippet(), "SKILL.md", "exec"), {"__name__": "__main__"})
    except SystemExit as e:
        code = 1 if isinstance(e.code, str) else (e.code or 0)
    finally:
        urllib.request.urlopen = real_urlopen
        sys.argv = real_argv
        sys.stdout, sys.stderr = real_stdout, real_stderr
    return code, out.getvalue(), err.getvalue()


def _run(responses, want="speech"):
    """Execute the snippet with a stubbed urlopen.

    `responses` maps a URL substring -> list of payloads (or an Exception to
    raise). Each call pops the next payload, repeating the last one forever so a
    non-advancing cursor can be simulated.
    """
    def fake_urlopen(url, timeout=30):
        for frag, seq in responses.items():
            if frag in url:
                if isinstance(seq, Exception):
                    raise seq
                payload = seq[0] if len(seq) == 1 else seq.pop(0)
                return io.BytesIO(json.dumps(payload).encode())
        raise AssertionError(f"unstubbed URL: {url}")

    return _exec_snippet(fake_urlopen, ["snippet", want])


OPENAI = "api/v1/models"
ANTHROPIC = "api/anthropic"
VERTEX = "api/vertex-ai"

def _page(models, **extra):
    return {"data": models, **extra}

def _tts(mid="x/tts"):
    return {"id": mid, "output_modalities": ["speech"]}


def _all(payload_openai, payload_anthropic=None, payload_vertex=None):
    return {
        ANTHROPIC: payload_anthropic or [_page([])],
        VERTEX: payload_vertex or [{"models": []}],
        OPENAI: payload_openai,
    }


def test_clean_read_counts_all_three():
    code, out, err = _run(_all([_page([_tts()], has_more=False)]))
    assert code == 0
    assert "fully read 3/3 catalogs" in out
    assert "PARTIAL" not in out
    assert "x/tts" in out


def test_missing_cursor_is_partial_and_not_counted():
    """has_more=true with no last_id: short read must not count as complete."""
    code, out, err = _run(_all([_page([_tts()], has_more=True)]))
    assert code == 0
    assert "fully read 2/3 catalogs" in out, out
    assert "SOME READS PARTIAL" in out
    assert "PARTIAL" in err


def test_repeated_cursor_does_not_loop():
    """A cursor that never advances must stop, not refetch the same page 50x."""
    code, out, err = _run(_all([_page([_tts()], has_more=True, last_id="same")]))
    assert code == 0
    # Two fetches, not fifty: page 1 records the cursor and follows it, page 2
    # sees the repeat and stops. The bound is what matters — without the
    # seen-set this would be 50 identical fetches and 'speech': 50.
    assert "'speech': 2" in out, out
    assert "SOME READS PARTIAL" in out
    assert "repeated" in err


def test_page_cap_is_reached_and_classified_partial():
    """Advancing cursors forever must stop at the cap and count as PARTIAL.

    Distinct from the repeated-cursor case: here every cursor IS new, so the
    seen-set never fires and only the cap (or the wall-clock budget) can stop
    the loop. Without this case the cap branch was asserted in prose only.
    """
    counter = {"n": 0}

    def endless(url, timeout=30):
        counter["n"] += 1
        body = {"data": [_tts(f"x/tts{counter['n']}")],
                "has_more": True, "last_id": f"cursor{counter['n']}"}
        return io.BytesIO(json.dumps(body).encode())

    code, out, err = _exec_snippet(endless, ["snippet", "speech"])

    # EVERY catalog pages forever, so none is fully read. All four assertions
    # are needed: without the exit-code check a regression that counts a capped
    # catalog as fully read still passes; without the lower bound on fetches a
    # regression that stops after ONE page also passes, since it too prints
    # PARTIAL and exits non-zero.
    assert code != 0, out                                # must not report success
    assert "fully read 0/3" in out                       # nothing was fully read
    assert "PARTIAL" in err
    # Positive evidence from pages that DID return survives the non-zero exit.
    assert "x/tts" in out
    assert counter["n"] > 3, counter["n"]               # actually paginated
    assert counter["n"] <= 3 * 20 + 3, counter["n"]     # and stayed bounded


@pytest.mark.parametrize("bad", [None, "yes", 1, []])
def test_malformed_has_more_is_partial(bad):
    """A non-bool has_more must not be read as 'this was the last page'."""
    code, out, err = _run(_all([_page([_tts()], has_more=bad)]))
    assert code == 0
    assert "fully read 2/3 catalogs" in out, out
    assert "not a bool" in err


def test_absent_has_more_counts_as_complete():
    """The documented residual, pinned so a change to it is deliberate.

    Both non-paginating catalogs omit the field entirely, so absent MUST mean
    done — otherwise every ordinary run reports PARTIAL. The cost is that a
    truncated response which drops the field is indistinguishable from one that
    never carried it.
    """
    code, out, err = _run(_all([_page([_tts()])]))   # no has_more key at all
    assert code == 0
    assert "fully read 3/3 catalogs" in out
    assert "PARTIAL" not in out


def test_schema_change_drops_only_that_catalog():
    code, out, err = _run(_all([{"data": {"not": "a list"}}]))
    assert code == 0
    assert "fully read 2/3 catalogs" in out
    assert "not a list" in err


def test_dead_endpoint_does_not_hide_the_others():
    code, out, err = _run(_all(OSError("connection refused")))
    assert code == 0
    assert "fully read 2/3 catalogs" in out
    assert "unavailable" in err


def test_total_failure_exits_nonzero():
    """Every catalog down must NOT read as 'ZenMux offers nothing'."""
    boom = OSError("down")
    code, out, err = _run({OPENAI: boom, ANTHROPIC: boom, VERTEX: boom})
    assert code != 0
    assert "fully read 0/3" in out
    assert "unavailable" in err


def test_midway_failure_keeps_earlier_pages():
    """A failure on page 2 must not unsee page 1.

    Page 1 returns a real model and a cursor; page 2 dies. The catalog is
    PARTIAL (not counted as fully read), but the model observed on page 1 is
    genuine positive evidence and must still be reported.
    """
    state = {"n": 0}

    def flaky(url, timeout=30):
        if "api/v1/models" not in url:
            return io.BytesIO(json.dumps({"data": [], "models": []}).encode())
        state["n"] += 1
        if state["n"] == 1:
            body = _page([_tts("x/page1")], has_more=True, last_id="c1")
            return io.BytesIO(json.dumps(body).encode())
        raise OSError("page 2 died")

    _code, out, err = _exec_snippet(flaky, ["snippet", "speech"])

    assert "x/page1" in out, out                          # page 1 survived
    assert "SOME READS PARTIAL" in out                    # but flagged partial


def test_malformed_entry_skipped_without_aborting():
    code, out, err = _run(_all([_page(["not-a-dict", _tts()], has_more=False)]))
    assert code == 0
    assert "fully read 3/3 catalogs" in out
    assert "x/tts" in out


def test_entry_without_id_is_not_listed():
    """A hit with no usable id is not selectable, so it must not be offered."""
    code, out, err = _run(_all([_page([{"output_modalities": ["speech"]}], has_more=False)]))
    assert code == 0
    assert "'speech': 1" in out   # counted in the vocabulary map
    assert "None" not in out      # but never printed as a selectable model


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
