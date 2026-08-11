/**
 * run-with-flags.js — oversized-stdin fail-CLOSED backstop (#612).
 *
 * run-with-flags.js caps stdin at MAX_STDIN = 1 MiB. Past that the payload is
 * truncated mid-JSON, so a hook whose run() returns the input unchanged on a
 * parse error (GateGuard does exactly this) reported "allow" — and the runner
 * exited 0 even under --fail-closed. A single >1 MiB Write was enough to walk
 * past a blocking gate.
 *
 * The runner now overrides an exit-0 allow to exit 2 when the payload was
 * truncated AND --fail-closed was passed: an allow computed from input the
 * hook could not fully see is not a confirmed allow.
 *
 * Same subprocess harness as run-with-flags-await.test.ts — the runner reads
 * stdin at import scope, so it can only be exercised as a real dispatch.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { spawnSync } from 'node:child_process'
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.resolve(here, '..')
const RUNNER = path.join(REPO_ROOT, 'scripts', 'hooks', 'run-with-flags.js')

const MAX_STDIN = 1024 * 1024

// Strictly over the cap. Exactly MAX_STDIN is NOT truncated — the runner's
// check is `chunk.length > remaining`, so equality passes through intact.
// ASCII filler only: the cap is enforced in UTF-8 bytes, and ASCII bytes and
// UTF-16 code units are 1:1, so this stays a clean over-the-cap case either way.
function oversizedPayload(): string {
  const filler = 'x'.repeat(MAX_STDIN)
  return `{"tool":"Write","tool_input":{"file_path":"/tmp/big.txt","content":"${filler}"}}`
}

// Multi-byte payload: 'é' is 1 UTF-16 code unit but 2 UTF-8 bytes. A cap that
// measured decoded string length instead of raw bytes would read this as
// under MAX_STDIN units while it is actually ~2x MAX_STDIN bytes — exactly
// the gap CodeRabbit/cubic flagged in review of #612's enforceTruncation.
function oversizedMultibytePayload(): string {
  const filler = 'é'.repeat(MAX_STDIN)
  return `{"tool":"Write","tool_input":{"file_path":"/tmp/big.txt","content":"${filler}"}}`
}

let tmpRoot: string

function writeFixture(name: string, body: string): string {
  fs.writeFileSync(path.join(tmpRoot, name), body)
  return name // relative path passed as scriptRelPath
}

function runDispatch(args: string[], stdin: string) {
  return spawnSync('node', [RUNNER, ...args], {
    input: stdin,
    encoding: 'utf8',
    maxBuffer: 8 * 1024 * 1024,
    env: {
      ...process.env,
      CLAUDE_PLUGIN_ROOT: tmpRoot,
      ECC_HOOK_PROFILE: 'standard',
    },
  })
}

// Written verbatim (no interpolation) into generated fixture source — see the
// same constant in run-with-flags-await.test.ts for why a static literal is
// used instead of JSON.stringify().
const BLOCK_LITERAL = "'{\"decision\":\"block\",\"reason\":\"gate says no\"}'"

beforeAll(() => {
  tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'rwf-trunc-'))
})
afterAll(() => {
  fs.rmSync(tmpRoot, { recursive: true, force: true })
})

describe('run-with-flags oversized stdin under --fail-closed', () => {
  it('blocks (exit 2) when a pass-through hook allows a truncated payload', () => {
    // GateGuard's parse-error shape: `return rawInput` — an unconditional allow.
    const rel = writeFixture('passthrough.js', 'module.exports = { run: raw => raw };')
    const r = runDispatch(['pre:test-trunc', rel, 'standard', '--fail-closed'], oversizedPayload())
    expect(r.status).toBe(2)
    // Never echo a JSON document cut mid-stream (#2222).
    expect(r.stdout).toBe('')
    // The block must name why (#612 review: assert the reason actually reaches
    // the operator, not just the exit code).
    expect(r.stderr).toContain('truncated')
  })

  it('blocks (exit 2) on a multi-byte payload that exceeds MAX_STDIN bytes but not MAX_STDIN UTF-16 units', () => {
    const rel = writeFixture('passthrough-mb.js', 'module.exports = { run: raw => raw };')
    const r = runDispatch(['pre:test-trunc-mb', rel, 'standard', '--fail-closed'], oversizedMultibytePayload())
    expect(r.status).toBe(2)
    expect(r.stdout).toBe('')
    expect(r.stderr).toContain('truncated')
  })

  it('keeps the hook block decision when the hook blocks on its own', () => {
    const rel = writeFixture(
      'trunc-block.js',
      `module.exports = { run: () => ({ exitCode: 2, stdout: ${BLOCK_LITERAL} }) };`,
    )
    const r = runDispatch(['pre:test-trunc-block', rel, 'standard', '--fail-closed'], oversizedPayload())
    expect(r.status).toBe(2)
    // sanitizeEcho only blanks output identical to the raw input, so a hook's
    // own block message still reaches the operator.
    expect(r.stdout).toContain('"decision":"block"')
  })

  it('blocks (exit 2) when a legacy no-run()-export hook exits 0', () => {
    // The legacy spawnSync path is a separate exit site from the run() path.
    // The fixture must drain stdin before exiting or the 1 MiB write EPIPEs.
    const rel = writeFixture(
      'legacy-allow.js',
      "process.stdin.resume(); process.stdin.on('end', () => process.exit(0));",
    )
    const r = runDispatch(['pre:test-trunc-legacy', rel, 'standard', '--fail-closed'], oversizedPayload())
    expect(r.status).toBe(2)
  })
})

describe('run-with-flags oversized stdin without --fail-closed', () => {
  it('stays fail-OPEN (exit 0) for an advisory dispatch', () => {
    // Advisory hooks must not gain a block they never had — an env-driven or
    // unconditional block here would let an oversized payload DoS every
    // non-gate hook. The override keys off argv only.
    const rel = writeFixture('advisory.js', 'module.exports = { run: raw => raw };')
    const r = runDispatch(['pre:test-trunc-advisory', rel, 'standard'], oversizedPayload())
    expect(r.status).toBe(0)
    expect(r.stdout).toBe('')
  })
})
