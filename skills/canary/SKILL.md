---
name: canary
description: Post-deploy canary monitoring — baseline capture + continuous monitoring loop with transient tolerance and relative thresholds. Use after shipping to detect first-hour production regressions.
---

# Post-Deploy Canary Monitor

Monitor production health after deployment by comparing against a pre-deploy baseline. Detects regressions in page load times, console errors, and page availability.

## When to Use

- After running `busdriver:finishing-a-development-branch` and deploying
- After any production deployment
- When the user says "monitor the deploy", "is the deploy healthy?", "canary check"

## Modes

### Baseline Mode (run BEFORE deploying)

Capture the current healthy state:

1. Get the production URL and key pages from the user (or detect from project config)
2. For each page:
   - Navigate and record: HTTP status, load time, console error count, network error count
   - Take a snapshot of the page content (text summary, not screenshot)
3. Save baseline to `.claude/canary-baseline.local.json`:

```json
{
  "captured_at": "2026-03-23T15:30:00Z",
  "commit": "abc123",
  "pages": {
    "/": { "status": 200, "load_ms": 450, "console_errors": 0, "network_errors": 0 },
    "/dashboard": { "status": 200, "load_ms": 800, "console_errors": 0, "network_errors": 0 }
  }
}
```

### Monitor Mode (run AFTER deploying)

Compare current state against baseline in a loop:

1. Load baseline from `.claude/canary-baseline.local.json`
2. Every 60 seconds, check each page:
   - Navigate, record same metrics as baseline
   - Compare against baseline thresholds (see Alert Levels below)
3. Report results after each check cycle
4. Stop after 10 clean cycles (10 minutes) or on user interrupt

## Alert Levels

| Level | Trigger | Action |
|-------|---------|--------|
| CRITICAL | Page returns 5xx or fails to load | Stop monitoring, alert immediately |
| HIGH | New console errors not in baseline | Alert, continue monitoring |
| MEDIUM | Load time >2x baseline OR >500ms absolute increase | Warn, continue monitoring |
| LOW | New 404 resources not in baseline | Note, continue monitoring |

## Transient Tolerance

A finding only becomes an alert if it persists across **2 consecutive checks**. Single occurrences are logged but not alerted — they may be transient network issues, cold caches, or deployment propagation delays.

## Relative Thresholds (Not Absolute)

Compare against YOUR baseline, not industry standards:
- If your page normally loads in 200ms and now takes 500ms → that's a 2.5x regression → MEDIUM alert
- If your page normally loads in 2000ms and now takes 2300ms → that's 1.15x → no alert
- New console errors matter even if baseline had zero errors

## Health Report

After monitoring completes (10 clean cycles or user stop):

```
Canary Health Report
────────────────────
Baseline: abc123 (2026-03-23 15:30)
Current:  def456 (2026-03-23 16:00)
Duration: 10 minutes (10 cycles)

Page Results:
  / .............. HEALTHY (avg 460ms, baseline 450ms, +2%)
  /dashboard ..... HEALTHY (avg 820ms, baseline 800ms, +2.5%)
  /settings ...... WARN (avg 1600ms, baseline 750ms, +113%) ← MEDIUM

Overall: HEALTHY (1 warning)
```

## Baseline Update

If the deploy is healthy after monitoring:
- Offer to update the baseline: "Deploy looks healthy. Update canary baseline to current commit?"
- If accepted, overwrite `.claude/canary-baseline.local.json` with current metrics

## Browser Requirements

This skill requires browser access via Playwright MCP, Chrome DevTools MCP, or agent-browser CLI. If no browser tool is available, fall back to `curl` for basic HTTP status and timing checks (no console error detection).
