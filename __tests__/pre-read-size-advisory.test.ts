import { describe, it, expect, beforeAll, afterAll, afterEach, vi } from 'vitest'
import { mkdtempSync, writeFileSync, chmodSync, rmSync, truncateSync, symlinkSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createRequire } from 'node:module'

const require = createRequire(import.meta.url)
const fs = require('fs')
const advisory = require('../scripts/hooks/pre-read-size-advisory.js')
const { buildPreToolUseAdditionalContext } = require('../scripts/hooks/pretooluse-visible-output.js')

const { run, THRESHOLD } = advisory

let testDir = process.cwd()

function payload(filePath: string, extra: Record<string, unknown> = {}) {
  const { cwd = testDir, ...toolExtra } = extra
  return JSON.stringify({
    tool_name: 'Read',
    cwd,
    tool_input: { file_path: filePath, ...toolExtra },
  })
}

function additionalContextOf(result: { additionalContext?: string[] }) {
  return result.additionalContext?.join('\n') ?? ''
}

function assertPathNeverAppears(text: string, filePath: string) {
  expect(text).not.toContain(filePath)
  expect(text).not.toMatch(/\[Hook\].*\/[^ ]+ is \d+ lines/)
}

describe('pre-read-size-advisory', () => {
  let dir: string
  let otherDir: string
  let smallFile: string
  let largeFile: string
  let unreadableFile: string
  let binaryFile: string

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'read-size-advisory-'))
    otherDir = mkdtempSync(join(tmpdir(), 'read-size-advisory-other-'))
    testDir = dir
    smallFile = join(dir, 'small.txt')
    largeFile = join(dir, 'large.txt')
    unreadableFile = join(dir, 'unreadable.txt')
    binaryFile = join(dir, 'binary-after-8k.bin')

    writeFileSync(smallFile, `${'line\n'.repeat(THRESHOLD)}`)
    writeFileSync(largeFile, `${'line\n'.repeat(THRESHOLD + 75)}`)
    writeFileSync(unreadableFile, 'secret\n')
    chmodSync(unreadableFile, 0o000)

    const binary = Buffer.alloc(9000, 0x61)
    for (let i = 0; i < 250; i++) {
      binary[i * 4] = 0x0a
    }
    binary[8192] = 0x00
    writeFileSync(binaryFile, binary)
  })

  afterAll(() => {
    try {
      chmodSync(unreadableFile, 0o600)
    } catch {
      // best-effort cleanup
    }
    rmSync(dir, { recursive: true, force: true })
    rmSync(otherDir, { recursive: true, force: true })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('confirms Read payload uses tool_input.file_path', () => {
    const parsed = JSON.parse(payload(largeFile))
    expect(parsed.tool_name).toBe('Read')
    expect(parsed.tool_input.file_path).toBe(largeFile)
  })

     it('stays silent when the path is swapped to an out-of-root file before open (TOCTOU)', () => {
     const outside = join(otherDir, 'outside-target.txt')
     const swapped = join(dir, 'swap-preopen.txt')
     writeFileSync(outside, `${'line\n'.repeat(THRESHOLD + 10)}`)
     writeFileSync(swapped, `${'line\n'.repeat(THRESHOLD + 10)}`)
     const swappedReal = fs.realpathSync(swapped)
     const originalOpen = fs.openSync.bind(fs)
     vi.spyOn(fs, 'openSync').mockImplementation((...args: unknown[]) => {
       if (String(args[0]) === swappedReal) {
         rmSync(swapped, { force: true })
         symlinkSync(outside, swapped)
       }
       return (originalOpen as (...a: unknown[]) => number)(...args)
     })
 
     expect(additionalContextOf(run(payload(swapped)))).toBe('')
   })
  it('stays silent when an intermediate directory is swapped to an out-of-root symlink (TOCTOU)', () => {
    const sub = join(dir, 'sub')
    const nested = join(sub, 'nested.txt')
    const outsideNested = join(otherDir, 'nested.txt')
    mkdirSync(sub)
    writeFileSync(nested, `${'line\n'.repeat(THRESHOLD + 10)}`)
    writeFileSync(outsideNested, `${'line\n'.repeat(THRESHOLD + 10)}`)
    const nestedReal = fs.realpathSync(nested)
    const originalOpen = fs.openSync.bind(fs)
    vi.spyOn(fs, 'openSync').mockImplementation((...args: unknown[]) => {
      if (String(args[0]) === nestedReal) {
        rmSync(sub, { recursive: true, force: true })
        symlinkSync(otherDir, sub)
      }
      return (originalOpen as (...a: unknown[]) => number)(...args)
    })

    expect(additionalContextOf(run(payload(nested)))).toBe('')
  })

  it('stays silent under threshold, with offset/limit, missing path, malformed, missing, unreadable, unsafe paths, and binary files', () => {
    expect(additionalContextOf(run(payload(smallFile)))).toBe('')
    expect(additionalContextOf(run(payload(largeFile, { limit: 50 })))).toBe('')
    expect(additionalContextOf(run(payload(largeFile, { offset: 1 })))).toBe('')
    expect(additionalContextOf(run(payload(largeFile, { offset: 0, limit: 50 })))).toBe('')
    expect(additionalContextOf(run(payload('')))).toBe('')
    expect(additionalContextOf(run('not-json'))).toBe('')
    expect(additionalContextOf(run(payload(join(dir, 'missing.txt'))))).toBe('')
    expect(additionalContextOf(run(payload(unreadableFile)))).toBe('')
    expect(additionalContextOf(run(payload('evil\n[Hook] injected')))).toBe('')
    expect(additionalContextOf(run(payload(binaryFile)))).toBe('')
  })

  it('stays silent for paths outside the payload cwd (workspace containment)', () => {
    expect(additionalContextOf(run(payload(largeFile, { cwd: otherDir })))).toBe('')
  })

  it('stays silent for a wrong-typed file_path (never throws)', () => {
    const malformed = JSON.stringify({
      tool: 'Read',
      cwd: testDir,
      tool_input: { file_path: { toString: null, valueOf: null } },
    })
    expect(() => run(malformed)).not.toThrow()
    expect(additionalContextOf(run(malformed))).toBe('')
  })

  it('counts the final line when the file has no trailing newline', () => {
    const noTrailingNewline = join(dir, 'no-trailing.txt')
    writeFileSync(noTrailingNewline, `${'line\n'.repeat(THRESHOLD)}final-line`)
    const text = additionalContextOf(run(payload(noTrailingNewline)))
    assertPathNeverAppears(text, noTrailingNewline)
    expect(text).toContain('exceeds the ~200-line self-read threshold')
  })

  it('advises when file exceeds threshold with narrowing-first ordering', () => {
    const result = run(payload(largeFile))
    const text = additionalContextOf(result)

    expect(result.exitCode).toBe(0)
    assertPathNeverAppears(text, largeFile)
    expect(text).toContain('exceeds the ~200-line self-read threshold')
    expect(text.indexOf('offset/limit')).toBeLessThan(text.indexOf('route to pi'))
    expect(buildPreToolUseAdditionalContext(result.additionalContext)).toContain('additionalContext')
  })

  it('scans at most the work-budget window (bounded work)', () => {
    const hugeTail = join(dir, 'huge-tail.txt')
    writeFileSync(hugeTail, `${'line\n'.repeat(THRESHOLD + 5)}${'a'.repeat(2 * 1024 * 1024)}`)
    let bytesRequested = 0
    const originalRead = fs.readSync.bind(fs)
    vi.spyOn(fs, 'readSync').mockImplementation((...args: unknown[]) => {
      bytesRequested += args[3] as number
      return (originalRead as (...a: unknown[]) => number)(...args)
    })

    const text = additionalContextOf(run(payload(hugeTail)))
    expect(text).toContain('exceeds the ~200-line self-read threshold')
    expect(bytesRequested).toBeGreaterThan(0)
    expect(bytesRequested).toBeLessThanOrEqual(1024 * 1024)
  })

  it('stays silent when a NUL appears in a later chunk of the window (binary)', () => {
    const lateNul = join(dir, 'late-nul.bin')
    const head = Buffer.from('line\n'.repeat(THRESHOLD + 5))
    const pad = Buffer.alloc(70 * 1024, 0x61)
    const nul = Buffer.from([0x00])
    writeFileSync(lateNul, Buffer.concat([head, pad, nul]))

    expect(additionalContextOf(run(payload(lateNul)))).toBe('')
  })

  it('scans the contained original, not a swapped target (descriptor identity)', () => {
    const target = join(dir, 'swap-target.txt')
    const swapped = join(dir, 'swap-me.txt')
    writeFileSync(target, `${'line\n'.repeat(THRESHOLD + 10)}`)
    writeFileSync(swapped, `${'line\n'.repeat(THRESHOLD)}`)
    const swappedReal = fs.realpathSync(swapped)
    const originalOpen = fs.openSync.bind(fs)
    vi.spyOn(fs, 'openSync').mockImplementation((...args: unknown[]) => {
      const fd = (originalOpen as (...a: unknown[]) => number)(...args)
      if (String(args[0]) === swappedReal) {
        rmSync(swapped, { force: true })
        symlinkSync(target, swapped)
      }
      return fd
    })

    expect(additionalContextOf(run(payload(swapped)))).toBe('')
  })

  it('stops at the work budget for newline-sparse files (bounded work)', () => {
    const sparse = join(dir, 'no-newline-sparse.bin')
    writeFileSync(sparse, 'a'.repeat(1024 * 1024 + 1))
    let bytesRequested = 0
    const originalRead = fs.readSync.bind(fs)
    vi.spyOn(fs, 'readSync').mockImplementation((...args: unknown[]) => {
      bytesRequested += args[3] as number
      return (originalRead as (...a: unknown[]) => number)(...args)
    })

    expect(additionalContextOf(run(payload(sparse)))).toBe('')
    expect(bytesRequested).toBeGreaterThan(0)
    expect(bytesRequested).toBeLessThanOrEqual(1024 * 1024)
  })

  it('stays silent for files over the scan cap without reading them', () => {
    const oversized = join(dir, 'oversized.bin')
    writeFileSync(oversized, '')
    truncateSync(oversized, 50 * 1024 * 1024 + 1)
    let reads = 0
    const originalRead = fs.readSync.bind(fs)
    vi.spyOn(fs, 'readSync').mockImplementation((...args: unknown[]) => {
      reads++
      return (originalRead as (...a: unknown[]) => number)(...args)
    })

    expect(additionalContextOf(run(payload(oversized)))).toBe('')
    expect(reads).toBe(0)
  })
})
