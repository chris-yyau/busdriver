---
name: browser-automation
description: >
  Route browser automation tasks to the right tool: Playwright MCP, Chrome DevTools MCP, or
  agent-browser CLI. Use when interacting with web pages, testing UI, taking screenshots, running
  Lighthouse audits, performance profiling, filling forms, automating login flows, debugging web
  apps, mobile testing, or any task requiring a browser. Triggers on: "open this page", "click",
  "test this UI", "Lighthouse audit", "performance trace", "screenshot", "fill form", "login to",
  "automate browser", "check accessibility", "profile page speed", "memory leak", "mobile test",
  "emulate device", or any browser interaction task.
---

# Browser Automation Tool Router

Three browser tools available: **Playwright MCP**, **Chrome DevTools MCP**, and **agent-browser CLI**. Plus **Firecrawl Browser** for cloud-hosted sessions (see `web-research` skill).

## Tool Selection Matrix

| Need | Tool | Why |
|------|------|-----|
| Simple page interaction, click/type/navigate | **Playwright** `mcp__Playwright__*` | Clean managed browser, snapshot+ref model, zero setup |
| E2E test scripting (custom Playwright code) | **Playwright** `browser_run_code` | Run arbitrary Playwright JS with `page` object |
| Tab management | **Playwright** `browser_tabs` | List, create, close, select tabs |
| Lighthouse audit (accessibility, SEO, best practices) | **Chrome DevTools** `lighthouse_audit` | Only tool with Lighthouse integration |
| Performance profiling (Core Web Vitals, LCP, INP, CLS) | **Chrome DevTools** `performance_start_trace` | Only tool with performance tracing |
| Memory leak debugging | **Chrome DevTools** `take_memory_snapshot` | Only tool with heap snapshots |
| Device emulation (viewport, dark mode, network throttle, geo) | **Chrome DevTools** `emulate` | Richest emulation: color scheme, CPU throttle, network conditions, geolocation, user agent |
| Inspect network requests/responses in detail | **Chrome DevTools** `list_network_requests` + `get_network_request` | Filter by resource type, save request/response bodies to files |
| Inspect console messages by type | **Chrome DevTools** `list_console_messages` | Filter by message type (error, warn, etc.), paginated |
| Connect to existing Chrome instance | **Chrome DevTools** or **agent-browser** `--auto-connect` / `--cdp` | Both support CDP connection |
| Auth flows with session persistence | **agent-browser** | Save/restore cookies & localStorage, encrypted state |
| Parallel browser sessions | **agent-browser** `--session` | Named sessions for concurrent work |
| iOS Simulator / mobile Safari | **agent-browser** `-p ios` | Only tool with real iOS Simulator support |
| Video recording of browser session | **agent-browser** `record start` | Built-in recording |
| Semantic locators (find by text/role/label) | **agent-browser** `find` command | When refs are unreliable |
| Open local files (PDF, HTML) | **agent-browser** `--allow-file-access` | file:// URL support |
| Headed/visual debugging | **agent-browser** `--headed` | See the browser, highlight elements |
| Cloud-hosted browser (no local Chrome needed) | **Firecrawl Browser** `firecrawl_browser_*` | See `web-research` skill |

## Decision Tree

```
What do you need?
  |
  |--> Audit/Profile (Lighthouse, perf, memory)?
  |      --> Chrome DevTools (only option)
  |
  |--> Emulate device conditions (network, geo, dark mode)?
  |      --> Chrome DevTools (richest emulation)
  |
  |--> Persistent auth, parallel sessions, iOS, video?
  |      --> agent-browser (unique features)
  |
  |--> Simple page interaction (navigate, click, fill, screenshot)?
  |      --> Playwright (cleanest API, managed browser)
  |      --> OR agent-browser (if already in a session or need CLI)
  |
  |--> Custom Playwright scripting?
  |      --> Playwright `browser_run_code`
  |
  |--> No local browser available?
         --> Firecrawl Browser (cloud CDP)
```

## Interaction Model (shared across all three)

All three tools use the same **snapshot + ref** pattern:

1. **Navigate** to a URL
2. **Snapshot** the page (a11y tree with element references)
3. **Interact** using refs from the snapshot (click, fill, etc.)
4. **Re-snapshot** after any navigation or DOM change (refs are invalidated)

| Step | Playwright | Chrome DevTools | agent-browser |
|------|-----------|-----------------|---------------|
| Navigate | `browser_navigate` | `navigate_page` | `open <url>` |
| Snapshot | `browser_snapshot` | `take_snapshot` | `snapshot -i` |
| Click | `browser_click` (ref) | `click` (uid) | `click @e1` |
| Fill | `browser_type` (ref) | `fill` (uid) | `fill @e1 "text"` |
| Screenshot | `browser_take_screenshot` | `take_screenshot` | `screenshot` |
| Evaluate JS | `browser_evaluate` | `evaluate_script` | `eval 'expr'` |

## When NOT to use browser tools

- **Just need page content?** Use Firecrawl Scrape (`web-research` skill) — no browser overhead
- **Just need search results?** Use Brave/Tavily (`web-research` skill)
- **Extracting structured data?** Use Firecrawl Extract — faster than scripting a browser

## Chrome DevTools: Unique Capabilities

### Lighthouse Audit
```
lighthouse_audit → accessibility, SEO, best practices scores
  - device: "desktop" or "mobile"
  - mode: "navigation" (reloads) or "snapshot" (current state)
```

### Performance Trace
```
1. navigate_page → go to the URL
2. performance_start_trace → start recording (auto-reloads by default)
3. performance_stop_trace → if autoStop: false
4. performance_analyze_insight → drill into specific insights (e.g., "LCPBreakdown", "DocumentLatency")
```

### Device Emulation
```
emulate → combine any of:
  - viewport: "375x812x3,mobile,touch" (iPhone-like)
  - colorScheme: "dark"
  - networkConditions: "Slow 3G"
  - cpuThrottlingRate: 4
  - geolocation: "37.7749x-122.4194" (San Francisco)
  - userAgent: custom string
```

### Memory Snapshot
```
take_memory_snapshot → .heapsnapshot file for leak debugging
```

## agent-browser: Unique Capabilities

### Session Persistence
```bash
agent-browser --session-name myapp open https://app.com/login
# ... login flow ...
agent-browser close  # State auto-saved

# Later — state auto-restored
agent-browser --session-name myapp open https://app.com/dashboard
```

### iOS Simulator
```bash
agent-browser -p ios --device "iPhone 16 Pro" open https://example.com
agent-browser -p ios snapshot -i
agent-browser -p ios tap @e1
```

### Semantic Locators (when refs fail)
```bash
agent-browser find text "Sign In" click
agent-browser find label "Email" fill "user@test.com"
agent-browser find role button click --name "Submit"
```

## Setup

**Playwright MCP** — configured in `~/.claude.json` under `mcpServers.Playwright`. No API key needed (local browser).

**Chrome DevTools MCP** — configured in `~/.claude.json` under `mcpServers.chrome-devtools`. Connects to Chrome via CDP. No API key needed.

**agent-browser** — CLI tool. Install: `npm install -g agent-browser`. No API key needed.
