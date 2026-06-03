/**
 * TEMPLATE TEST -- Copy this file as a starting point for new test files.
 *
 * Pattern: vitest unit tests for exported CommonJS functions.
 * Run:      npm test
 * Coverage: npm run test:coverage
 *
 * This repo is CommonJS (no "type": "module" in package.json). A module that
 * does `module.exports = { fn }` is imported as a DEFAULT import here, then
 * destructured — vitest's interop maps module.exports onto the default export.
 *
 * For a full TDD workflow on a specific module, use `busdriver:tdd`.
 * For more JS patterns, see `busdriver:react-testing` / `busdriver:python-testing`.
 */
import { describe, it, expect } from 'vitest'
import shellSplit from '../scripts/lib/shell-split.js'

const { splitShellSegments } = shellSplit

describe('splitShellSegments (real example)', () => {
  // Happy path: a simple chained command splits on the operator.
  it('splits a command on &&', () => {
    expect(splitShellSegments('npm run build && npm test')).toEqual([
      'npm run build',
      'npm test',
    ])
  })

  // Edge case: operators inside quotes are NOT separators.
  it('does not split inside quotes', () => {
    expect(splitShellSegments('echo "a && b"')).toEqual(['echo "a && b"'])
  })

  // Edge case: redirection (2>&1) must not be mistaken for the & separator.
  it('treats redirection as part of the segment, not a separator', () => {
    expect(splitShellSegments('cmd 2>&1; next')).toEqual(['cmd 2>&1', 'next'])
  })
})

describe('your module (replace these)', () => {
  // Copy the pattern above against your own exported functions.
  it.todo('returns the expected result for valid input')
  it.todo('throws / errors on invalid input')
})
