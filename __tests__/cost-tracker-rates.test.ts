import { describe, it, expect } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const HOOK = join(__dirname, '..', 'scripts', 'hooks', 'cost-tracker.js');
type Turn = { model: string; usage: Record<string, number> };

function costOf(turns: Turn[]): number {
  const home = mkdtempSync(join(tmpdir(), 'cost-tracker-'));
  const transcript = join(home, 't.jsonl');
  writeFileSync(transcript, turns.map(t => JSON.stringify({ type: 'assistant', message: t })).join('\n') + '\n');
  const input = JSON.stringify({ session_id: `rates-${process.pid}-${Date.now()}`, transcript_path: transcript });
  // ECC_AGENT_DATA_HOME outranks HOME in getClaudeDir(), so pin it too.
  const env = { ...process.env, HOME: home, USERPROFILE: home, ECC_AGENT_DATA_HOME: join(home, '.claude') };
  const res = spawnSync('node', [HOOK], { input, env });
  expect(res.status).toBe(0);
  const rows = readFileSync(join(home, '.claude', 'metrics', 'costs.jsonl'), 'utf8').trim().split('\n');
  return JSON.parse(rows[rows.length - 1]).estimated_cost_usd;
}

// 1M tokens in each bucket: the cost is in + out + cacheWrite + cacheRead.
const MILLION = { input_tokens: 1e6, output_tokens: 1e6, cache_creation_input_tokens: 1e6, cache_read_input_tokens: 1e6 };

describe('cost-tracker rate table', () => {
  it.each([
    ['claude-fable-5-2', 8 + 40 + 10 + 0.2],
    ['claude-opus-5-5[1m]', 4 + 20 + 5 + 0.2],   // must not fall to the opus-5 row
    ['claude-opus-5', 5 + 25 + 6.25 + 0.5],
    ['claude-opus-4-1-20250805', 15 + 75 + 18.75 + 1.5],
    ['claude-sonnet-5-5', 2 + 10 + 2.5 + 0.1],
    ['claude-sonnet-4-6', 3 + 15 + 3.75 + 0.3],
    ['claude-3-5-sonnet-20241022', 3 + 15 + 3.75 + 0.3],
    ['claude-3-sonnet-20240229', 3 + 15 + 3.75 + 0.3],
    ['claude-haiku-4-5-20251001', 1 + 5 + 1.25 + 0.1],
    ['claude-haiku-5-5', 0.5 + 2.5 + 0.625 + 0.05],  // 3M-token prompt → long-context tier
    ['claude-opus-9', 4 + 20 + 5 + 0.2],          // unknown version → current Opus
    ['claude-haiku-9', 0.5 + 2.5 + 0.625 + 0.05], // family fallback keeps the long-context tier
    ['claude-opus-40', 4 + 20 + 5 + 0.2],         // 'opus-4' must not claim a longer number
    ['claude-opus-5-6', 4 + 20 + 5 + 0.2],        // nor 'opus-5' an unlisted point release
    ['claude-opus-4-20250514', 15 + 75 + 18.75 + 1.5], // a date stamp is not a version
    ['claude-sonnet-4-5-20250929', 3 + 15 + 3.75 + 0.3],
  ])('%s', (model, expected) => {
    expect(costOf([{ model, usage: MILLION }])).toBeCloseTo(expected, 6);
  });

  it('prices Haiku 5.5 per request: a prompt at 100K stays on the low tier', () => {
    const usage = { input_tokens: 100000, output_tokens: 2000, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
    expect(costOf([{ model: 'claude-haiku-5-5', usage }])).toBeCloseTo(0.1 * 0.1 + 0.002 * 0.5, 6);
  });

  it('prices each turn at its own model in a mixed session', () => {
    const usage = { input_tokens: 1000, output_tokens: 3000, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
    const opus = (1000 * 4 + 3000 * 20) / 1e6;
    const fable = (1000 * 8 + 3000 * 40) / 1e6;
    expect(costOf([{ model: 'claude-opus-5-5', usage }, { model: 'claude-fable-5-2', usage }])).toBeCloseTo(opus + fable, 6);
  });
});
