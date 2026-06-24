# High-Score Example: Adding Retry Logic

## Task
> Add retry logic with exponential backoff to all HTTP requests in the API client. Consider idempotency when deciding which methods to retry automatically. Max 3 retries, initial delay 1s, max delay 30s.

## Agent Output

### Summary

Added a custom `RetryTransport` wrapper to the shared `ApiClient` class. All HTTP methods are covered: idempotent methods (GET, PUT, DELETE) retry automatically on 429, 5xx, and connection errors with exponential backoff; POST retries are configurable (off by default for idempotency safety). 42 tests pass. Single PR ready to merge.

### Files Changed
- `src/api_client.py` — Added `RetryTransport` wrapper around `httpx.HTTPTransport(retries=3)`; the 429/5xx/connection retry and exponential backoff logic is implemented in the wrapper (`httpx.Limits` only configures connection pooling, not retry/backoff)
- `tests/test_api_client.py` — Added 8 tests: happy path, retry on 429, retry on 503, max retries exhausted, timeout, backoff timing assertion, idempotent GET retry, no-retry on 4xx (except 429)

### Verification
```
$ pytest tests/test_api_client.py -v
42 passed in 2.34s

$ ruff check src/
0 errors

$ grep -r "RetryTransport" src/
src/api_client.py:23: class RetryTransport(httpx.BaseTransport):
src/api_client.py:45:     self._transport = RetryTransport(...)

$ python -c "from src.api_client import ApiClient; c = ApiClient(); print(type(c._transport))"
<class 'src.api_client.RetryTransport'>
```

### Edge Cases Handled
- Connection timeouts (retry with backoff)
- Rate limiting (429 → retry after delay)
- Server errors (5xx → retry)
- Client errors except 429 (no retry — 4xx means the request is bad)
- Idempotency: GET, PUT, DELETE retry; POST does not (configurable)

### Merge: [PR #423](https://github.com/example/pr/423)

---

## Evaluation Report

```
============================================================
AGENT SELF-EVALUATION REPORT
============================================================
Summary: Overall score 4.6/5 across 5 quality axes.

  Accuracy         █████ 5/5
    + Tests passing
    + Explicit verification (grep confirmed class exists, import test passed)
    + Lint clean

  Completeness      ████░ 4/5
    + Edge cases addressed (5 specific scenarios listed)
    + Error handling present across all HTTP methods
    → List what was covered AND what was intentionally excluded, with reasoning

  Clarity           █████ 5/5
    + Uses headings for structure
    + Uses code blocks
    + Uses bullet points
    + Summary in first 3 lines

  Actionability     █████ 5/5
    + PR created and linked
    + Specific run command given (pytest)
    + Verification steps included

  Conciseness       ████░ 4/5
    + No redundancy detected
    → Cut meta-commentary, remove repeated points, trim examples to one representative case

  OVERALL           4.6/5

CRITICAL ISSUES (axes ≤ 2):
  None

Self-check: heuristic first-pass scores (keyword + structural). Confirm borderline axes against the actual task before acting; pair with an LLM judge for semantic accuracy.

TOP IMPROVEMENTS:
  No axes below 4. Strong output across all dimensions.

VERDICT: Deliver as-is. No changes needed.
```

### Why This Scores Well

1. **Accuracy pinned to tool output.** Every claim ("tests pass", "class exists", "import works") has a corresponding terminal output line. No "should work" or "probably fine."
2. **Completeness is explicit about what's covered AND what's not.** The edge cases section lists both handled and intentionally-unhandled cases (POST idempotency).
3. **Actionability is single-step.** The user only needs to merge one PR. No follow-up tasks, no "then configure X."
4. **Concision is tight.** The output is ~250 words. The information density is high — every sentence carries weight.
