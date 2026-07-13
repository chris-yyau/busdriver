/**
 * Regression coverage for context-window detection used by the strategic-compact
 * hook. The bug: the transcript logs the model as bare "claude-opus-4-8" (the
 * harness's "[1m]" suffix is dropped), so marker-only detection fell back to the
 * 200k default and mislabeled a 1M window as 200k until context crossed 200k.
 */
import { describe, it, expect, afterEach } from 'vitest'
import transcriptContext from '../scripts/lib/transcript-context.js'

const {
  resolveContextWindowTokens,
  STANDARD_CONTEXT_WINDOW_TOKENS,
  LARGE_CONTEXT_WINDOW_TOKENS,
} = transcriptContext

describe('resolveContextWindowTokens', () => {
  const envKeys = ['ECC_CONTEXT_WINDOW_TOKENS', 'CLAUDE_CODE_AUTO_COMPACT_WINDOW']
  const saved = Object.fromEntries(envKeys.map((k) => [k, process.env[k]]))
  afterEach(() => {
    for (const k of envKeys) {
      if (saved[k] === undefined) delete process.env[k]
      else process.env[k] = saved[k]
    }
  })

  // The core regression: bare Opus 4.x id, low tokens, no marker -> large window.
  it('treats bare claude-opus-4-8 as the large window (marker dropped in transcript)', () => {
    expect(resolveContextWindowTokens(50000, 'claude-opus-4-8')).toBe(LARGE_CONTEXT_WINDOW_TOKENS)
  })

  it('still honors the explicit [1m] marker', () => {
    expect(resolveContextWindowTokens(1000, 'claude-opus-4-8[1m]')).toBe(LARGE_CONTEXT_WINDOW_TOKENS)
  })

  it('keeps the 200k default for non-large models below the token heuristic', () => {
    expect(resolveContextWindowTokens(50000, 'claude-haiku-4-5')).toBe(STANDARD_CONTEXT_WINDOW_TOKENS)
  })

  it('upgrades any model to large once observed tokens exceed 200k', () => {
    expect(resolveContextWindowTokens(250000, 'claude-haiku-4-5')).toBe(LARGE_CONTEXT_WINDOW_TOKENS)
  })

  it('lets an explicit env override win over family detection', () => {
    process.env.ECC_CONTEXT_WINDOW_TOKENS = '400000'
    expect(resolveContextWindowTokens(50000, 'claude-opus-4-8')).toBe(400000)
  })
})
