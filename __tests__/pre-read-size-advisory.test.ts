import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { mkdtempSync, writeFileSync, chmodSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createRequire } from 'node:module'
import { performance } from 'node:perf_hooks'

const require = createRequire(import.meta.url)
const advisory = require('../scripts/hooks/pre-read-size-advisory.js')
const { buildPreToolUseAdditionalContext } = require('../scripts/hooks/pretooluse-visible-output.js')

const { run, THRESHOLD } = advisory

function payload(filePath: string, extra: Record<string, unknown> = {}) {
  return JSON.stringify({
    tool: 'Read',
    tool_input: { file_path: filePath, ...extra },
  })
}

function additionalContextOf(result: { additionalContext?: string[] }) {
  return result.additionalContext?.join('\n') ?? ''
}

describe('pre-read-size-advisory', () => {
  let dir: string
  let smallFile: string
  let largeFile: string
  let unreadableFile: string

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'read-size-advisory-'))
    smallFile = join(dir, 'small.txt')
    largeFile = join(dir, 'large.txt')
    unreadableFile = join(dir, 'unreadable.txt')

    writeFileSync(smallFile, `${'line\n'.repeat(THRESHOLD)}`)
    writeFileSync(largeFile, `${'line\n'.repeat(THRESHOLD + 75)}`)
    writeFileSync(unreadableFile, 'secret\n')
    chmodSync(unreadableFile, 0o000)
  })

  afterAll(() => {
    try {
      chmodSync(unreadableFile, 0o600)
    } catch {
      // best-effort cleanup
    }
    rmSync(dir, { recursive: true, force: true })
  })

  it('confirms Read payload uses tool_input.file_path', () => {
    const parsed = JSON.parse(payload(largeFile))
    expect(parsed.tool).toBe('Read')
    expect(parsed.tool_input.file_path).toBe(largeFile)
  })

  it('stays silent under threshold, with limit, missing path, malformed, missing, unreadable, and unsafe paths', () => {
    expect(additionalContextOf(run(payload(smallFile)))).toBe('')
    expect(additionalContextOf(run(payload(largeFile, { limit: 50 })))).toBe('')
    expect(additionalContextOf(run(payload('')))).toBe('')
    expect(additionalContextOf(run('not-json'))).toBe('')
    expect(additionalContextOf(run(payload(join(dir, 'missing.txt'))))).toBe('')
    expect(additionalContextOf(run(payload(unreadableFile)))).toBe('')
    expect(additionalContextOf(run(payload('evil\n[Hook] injected')))).toBe('')
  })

  it('counts the final line when the file has no trailing newline', () => {
    const noTrailingNewline = join(dir, 'no-trailing.txt')
    writeFileSync(noTrailingNewline, `${'line\n'.repeat(THRESHOLD)}final-line`)
    expect(additionalContextOf(run(payload(noTrailingNewline)))).toContain(
      `${noTrailingNewline} is ${THRESHOLD + 1} lines`,
    )
  })

  it('advises on wholesale read over threshold with exact count and narrowing-first ordering', () => {
    const result = run(payload(largeFile))
    const text = additionalContextOf(result)

    expect(result.exitCode).toBe(0)
    expect(text).toContain(`${largeFile} is ${THRESHOLD + 75} lines`)
    expect(text.indexOf('offset/limit')).toBeLessThan(text.indexOf('route to pi'))
    expect(buildPreToolUseAdditionalContext(result.additionalContext)).toContain('additionalContext')
  })

  it('keeps per-read overhead under 50ms for local file line counting', () => {
    const start = performance.now()
    run(payload(largeFile))
    const elapsed = performance.now() - start

    expect(elapsed).toBeLessThan(50)
  })
})
