#!/usr/bin/env node
/**
 * Cost Tracker Hook (v2)
 *
 * Reads transcript_path from Stop hook stdin, sums usage across all
 * assistant turns in the session JSONL, and appends one row to
 * ~/.claude/metrics/costs.jsonl.
 *
 * Stop hook stdin payload: { session_id, transcript_path, cwd, hook_event_name, ... }
 * The Stop payload does NOT include `usage` or `model` directly. The previous
 * version of this hook expected those fields and silently produced zero-filled
 * rows (verified: 2,340 rows captured with 0.0% non-zero token rate over 52
 * days). The fix is to read the transcript file Claude Code already passes us.
 *
 * JSONL assistant entry shape (per Claude Code):
 *   { type: "assistant", message: { model, usage: { input_tokens, output_tokens,
 *     cache_creation_input_tokens, cache_read_input_tokens } } }
 *
 * Cumulative behavior: Stop fires per assistant response, not per session.
 * Each row therefore represents the cumulative session total up to that point.
 * To get per-session cost, take the last row per session_id. To get per-day
 * spend, aggregate.
 *
 * Harness-cost contract (optional, opt-in by the statusline):
 *   If the user's statusline (which receives `cost.total_cost_usd` directly
 *   from Claude Code) writes `{ts, cost_usd}` to
 *   `<os.tmpdir()>/harness-cost-<session_id>.json` on each render, this hook
 *   prefers that authoritative value over the transcript-sum estimate when
 *   the cache is fresh (≤ 300s). The transcript-sum is kept as a safe
 *   fallback because:
 *     - the hard-coded rate table cannot represent Opus 4.7's >200K-token
 *       2x tier or the 1h-cache 2x tier (under-counts on long sessions);
 *     - summing the full transcript double-counts work done across
 *       `--resume` boundaries while `cost.total_cost_usd` is per-process.
 *   Absent a writer, behavior is unchanged.
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { ensureDir, appendFile, getClaudeDir } = require('../lib/utils');
const { sanitizeSessionId } = require('../lib/session-bridge');

const HARNESS_COST_MAX_AGE_SECONDS = 300;

/**
 * Read authoritative harness cost from the per-session cache file.
 * @param {string} sessionId
 * @param {number} maxAgeSeconds
 * @returns {number|null} cost in USD, or null on miss / stale / parse error
 */
function readHarnessCost(sessionId, maxAgeSeconds) {
  if (!sessionId) return null;
  try {
    const fp = path.join(os.tmpdir(), `harness-cost-${sessionId}.json`);
    if (!fs.existsSync(fp)) return null;
    const obj = JSON.parse(fs.readFileSync(fp, 'utf8'));
    const ts = Number(obj && obj.ts);
    const cost = Number(obj && obj.cost_usd);
    if (!Number.isFinite(ts) || !Number.isFinite(cost) || cost < 0) return null;
    const age = Math.floor(Date.now() / 1000) - ts;
    if (age < 0 || age > maxAgeSeconds) return null;
    return cost;
  } catch {
    return null;
  }
}

// Per-1M-token list prices (USD), by model id. Cache write = 5-minute TTL
// (1.25x input). Cache-read multipliers differ by model, so each is listed.
// Only a fallback: the harness's own cost (readHarnessCost) wins when present.
const r = (inp, out, cacheRead) => ({ in: inp, out, cacheWrite: inp * 1.25, cacheRead });
// Ids match whole version segments (see idMatches), so 'opus-5' never claims 'opus-5-5'.
const RATE_TABLE = [
  ['fable-5-2',  r(8, 40, 0.20)],  ['mythos-5-2', r(8, 40, 0.20)],
  ['fable-5-1',  r(10, 50, 0.25)], ['mythos-5-1', r(10, 50, 0.25)],
  ['fable-5',    r(10, 50, 1.00)], ['mythos-5',   r(10, 50, 1.00)],
  ['opus-5-5',   r(4, 20, 0.20)],
  ['opus-5',     r(5, 25, 0.50)],
  ['opus-4-8',   r(5, 25, 0.50)], ['opus-4-7', r(5, 25, 0.50)],
  ['opus-4-6',   r(5, 25, 0.50)], ['opus-4-5', r(5, 25, 0.50)],
  ['opus-4-1',   r(15, 75, 1.50)], ['opus-4', r(15, 75, 1.50)],
  ['sonnet-5-5', r(2, 10, 0.10)],
  ['sonnet-5',   r(2, 10, 0.20)],
  ['sonnet-4-6', r(3, 15, 0.30)], ['sonnet-4-5', r(3, 15, 0.30)], ['sonnet-4', r(3, 15, 0.30)],
  ['haiku-5-5',  r(0.10, 0.50, 0.01)],
  ['haiku-4-5',  r(1, 5, 0.10)],
  // Claude 3.x ids put the family after the version (claude-3-5-sonnet-…).
  ['3-7-sonnet', r(3, 15, 0.30)], ['3-5-sonnet', r(3, 15, 0.30)], ['3-sonnet', r(3, 15, 0.30)],
  ['3-opus',     r(15, 75, 1.50)],
  ['3-5-haiku',  r(0.80, 4, 0.08)], ['3-haiku', r(0.25, 1.25, 0.03)]
];
// Haiku 5.5 bills a request whose prompt exceeds 100K tokens at a higher tier.
const HAIKU_5_5_LONG = r(0.50, 2.50, 0.05);
// Unknown version of a known family → that family's current model.
const FAMILY_DEFAULT = { fable: 'fable-5-2', mythos: 'mythos-5-2', opus: 'opus-5-5', sonnet: 'sonnet-5-5', haiku: 'haiku-5-5' };

// The id must not continue as another version number: 'opus-4' matches
// 'claude-opus-4-20250514' (date stamp) but not 'claude-opus-40' or 'claude-opus-4-9'.
function idMatches(model, id) {
  const at = model.indexOf(id);
  if (at < 0) return false;
  if (/[a-z0-9]/.test(model.charAt(at - 1))) return false;
  return !/^(\d|-\d{1,7}(?!\d))/.test(model.slice(at + id.length));
}

function getRates(model, promptTokens = 0) {
  const m = String(model || '').toLowerCase();
  const hit = RATE_TABLE.find(([id]) => idMatches(m, id));
  if (!hit) {
    const family = Object.keys(FAMILY_DEFAULT).find(f => m.includes(f)) || 'sonnet';
    return getRates(FAMILY_DEFAULT[family], promptTokens);
  }
  const longHaiku = hit[0] === 'haiku-5-5' && promptTokens > 100000;
  return longHaiku ? HAIKU_5_5_LONG : hit[1];
}

function toNumber(v) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

/**
 * Scan the session JSONL and sum token usage across all assistant turns.
 * Returns { inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens, model }
 * or null on read failure.
 */
function sumUsageFromTranscript(transcriptPath) {
  let content;
  try {
    content = fs.readFileSync(transcriptPath, 'utf8');
  } catch {
    return null;
  }

  let inputTokens = 0;
  let outputTokens = 0;
  let cacheWriteTokens = 0;
  let cacheReadTokens = 0;
  let model = 'unknown';
  let costUsd = 0;

  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }

    if (entry.type !== 'assistant') continue;
    const msg = entry.message;
    if (!msg || !msg.usage) continue;

    if (msg.model && msg.model !== 'unknown') model = msg.model;

    // Priced per turn: a session can switch models, and a tier can depend on one request's prompt size.
    const u = msg.usage;
    const inp = toNumber(u.input_tokens);
    const out = toNumber(u.output_tokens);
    const cw = toNumber(u.cache_creation_input_tokens);
    const cr = toNumber(u.cache_read_input_tokens);
    inputTokens += inp; outputTokens += out; cacheWriteTokens += cw; cacheReadTokens += cr;
    const rates = getRates(model, inp + cw + cr);
    costUsd += (inp * rates.in + out * rates.out + cw * rates.cacheWrite + cr * rates.cacheRead) / 1e6;
  }

  return { inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens, model, costUsd };
}

// 1MB, matching the other Stop hooks. The Stop payload carries
// last_assistant_message, which routinely exceeded the old 64KB cap and
// made this hook echo a JSON document cut mid-stream (#2090).
const MAX_STDIN = 1024 * 1024;
let raw = '';
let truncated = false;

process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  if (raw.length < MAX_STDIN) {
    const remaining = MAX_STDIN - raw.length;
    raw += chunk.substring(0, remaining);
    if (chunk.length > remaining) truncated = true;
  } else {
    truncated = true;
  }
});

process.stdin.on('end', () => {
  try {
    const input = raw.trim() ? JSON.parse(raw) : {};

    const transcriptPath = (typeof input.transcript_path === 'string' && input.transcript_path)
      ? input.transcript_path
      : process.env.CLAUDE_TRANSCRIPT_PATH || null;

    const sessionId =
      sanitizeSessionId(input.session_id) ||
      sanitizeSessionId(process.env.ECC_SESSION_ID) ||
      sanitizeSessionId(process.env.CLAUDE_SESSION_ID) ||
      'default';

    let usageTotals = null;
    if (transcriptPath && fs.existsSync(transcriptPath)) {
      usageTotals = sumUsageFromTranscript(transcriptPath);
    }

    const {
      inputTokens = 0,
      outputTokens = 0,
      cacheWriteTokens = 0,
      cacheReadTokens = 0,
      model = 'unknown',
      costUsd = 0
    } = usageTotals || {};

    const transcriptCostUsd = Math.round(costUsd * 1e6) / 1e6;

    // Prefer the harness's authoritative `cost.total_cost_usd` when the
    // statusline has written it to the per-session cache (see contract in
    // the file header). The harness number reflects API-billed truth
    // (correct rates, 1h-cache 2x, >200K tier 2x) and is per-process so it
    // does not drift across `--resume`. Cache miss → transcript-sum.
    const harnessCost = readHarnessCost(sessionId, HARNESS_COST_MAX_AGE_SECONDS);
    const estimatedCostUsd = harnessCost !== null
      ? Math.round(harnessCost * 1e6) / 1e6
      : transcriptCostUsd;

    const metricsDir = path.join(getClaudeDir(), 'metrics');
    ensureDir(metricsDir);

    const row = {
      timestamp:          new Date().toISOString(),
      session_id:         sessionId,
      transcript_path:    transcriptPath || '',
      model,
      input_tokens:       inputTokens,
      output_tokens:      outputTokens,
      cache_write_tokens: cacheWriteTokens,
      cache_read_tokens:  cacheReadTokens,
      estimated_cost_usd: estimatedCostUsd
    };

    appendFile(path.join(metricsDir, 'costs.jsonl'), `${JSON.stringify(row)}\n`);
  } catch {
    // Non-blocking — never fail the Stop hook.
  }

  // Pass stdin through (ECC hook convention) — but never echo truncated
  // stdin: invalid JSON on stdout is reported as a Stop hook failure (#2090).
  if (truncated) {
    process.stderr.write('[Hook] cost-tracker: stdin exceeded 1MB; suppressing pass-through (fail-open)\n');
    return;
  }
  process.stdout.write(raw);
});
