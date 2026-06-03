import { describe, it, expect } from 'vitest'

// Smoke test: prove the central utility module imports without crashing.
// Scope is import-only — no side effects, no child processes, no filesystem writes.
// scripts/lib/utils.js is CommonJS (module.exports = {...}); vitest's CJS interop
// surfaces module.exports as the default import.
import utils from '../scripts/lib/utils.js'

describe('smoke', () => {
  it('scripts/lib/utils.js imports without error', () => {
    expect(utils).toBeDefined()
    // A stable, representative export — if the module failed to evaluate,
    // this property would be undefined.
    expect(typeof utils.getHomeDir).toBe('function')
  })
})
