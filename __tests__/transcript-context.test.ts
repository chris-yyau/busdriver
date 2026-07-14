/**
 * Regression coverage for context-window detection used by the strategic-compact
 * hook. The bug: the transcript logs the model as bare "claude-opus-4-8" (the
 * harness's "[1m]" suffix is dropped), so marker-only detection fell back to the
 * 200k default and mislabeled the window as 200k until context crossed 200k.
 *
 * This is a solo, always-1M operator (see CLAUDE.md), so the fix resolves the
 * bare Opus 4.x family straight to the 1M window (the [1m] marker is dropped in
 * the transcript, so the marker check can never catch it). ECC_CONTEXT_WINDOW_TOKENS
 * remains the escape hatch for a standard (non-1M) session.
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import transcriptContext from '../scripts/lib/transcript-context.js'

const {
  resolveContextWindowTokens,
  STANDARD_CONTEXT_WINDOW_TOKENS,
  LARGE_CONTEXT_WINDOW_TOKENS,
} = transcriptContext

const ENV_KEYS = ['ECC_CONTEXT_WINDOW_TOKENS', 'CLAUDE_CODE_AUTO_COMPACT_WINDOW']

describe('resolveContextWindowTokens', () => {
  const saved = Object.fromEntries(ENV_KEYS.map((k) => [k, process.env[k]]))
  // Clear before each so a value already set in the runner can't leak into the
  // default-behavior cases (and restore original values after).
  beforeEach(() => ENV_KEYS.forEach((k) => delete process.env[k]))
  afterEach(() => {
    for (const k of ENV_KEYS) {
      if (saved[k] === undefined) delete process.env[k]
      else process.env[k] = saved[k]
    }
  })

  // Core regression: bare Opus 4.x id, no marker -> 1M window (always-1M
  // operator). Was the 200k default before #343, then the 400k floor.
  it('resolves the bare Opus 4.x family to the 1M window (marker dropped in transcript)', () => {
    expect(resolveContextWindowTokens(50000, 'claude-opus-4-8')).toBe(LARGE_CONTEXT_WINDOW_TOKENS)
  })

  // Token count is irrelevant for the family now — always the 1M window.
  it('keeps the Opus 4.x family at 1M regardless of observed token count', () => {
    expect(resolveContextWindowTokens(500000, 'claude-opus-4-8')).toBe(LARGE_CONTEXT_WINDOW_TOKENS)
  })

  it('still honors the explicit [1m] marker as the full 1M window', () => {
    expect(resolveContextWindowTokens(1000, 'claude-opus-4-8[1m]')).toBe(LARGE_CONTEXT_WINDOW_TOKENS)
  })

  // Anchored family match: "claude-opus-40" is a different model, not opus-4.
  it('does not false-match substring ids like claude-opus-40', () => {
    expect(resolveContextWindowTokens(50000, 'claude-opus-40')).toBe(STANDARD_CONTEXT_WINDOW_TOKENS)
  })

  it('keeps the 200k default for non-family models below the token heuristic', () => {
    expect(resolveContextWindowTokens(50000, 'claude-haiku-4-5')).toBe(STANDARD_CONTEXT_WINDOW_TOKENS)
  })

  it('upgrades a non-family model to 1M once observed tokens exceed 200k', () => {
    expect(resolveContextWindowTokens(250000, 'claude-haiku-4-5')).toBe(LARGE_CONTEXT_WINDOW_TOKENS)
  })

  it('lets an explicit env override win over family detection', () => {
    process.env.ECC_CONTEXT_WINDOW_TOKENS = '300000'
    expect(resolveContextWindowTokens(50000, 'claude-opus-4-8')).toBe(300000)
  })
})
