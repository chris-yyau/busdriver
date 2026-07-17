/**
 * run-with-flags.js — dispatch fail-open/fail-closed semantics (Task 7).
 *
 * run-with-flags.js runs main() at import scope and reads stdin, so it can't be
 * imported and unit-tested; these spawn it as a subprocess (the real dispatch
 * entry point) and assert exit code + stdout.
 *
 * Core regression: an async run() must be AWAITED. Before the fix, an async
 * run()'s Promise fell through resolveHookResult as a bare object and was
 * swallowed to exit 0 — a blocking gate would fail OPEN. These lock that in.
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

// A fixture hook must live UNDER CLAUDE_PLUGIN_ROOT to pass the path-traversal
// guard. We point CLAUDE_PLUGIN_ROOT at a tmp dir and drop the fixture there;
// run-with-flags.js still resolves its own ../lib/hook-flags from its real
// __dirname, so the tmp root only affects hook-script resolution.
let tmpRoot: string

function writeFixture(name: string, body: string): string {
  const p = path.join(tmpRoot, name)
  fs.writeFileSync(p, body)
  return name // relative path passed as scriptRelPath
}

function runDispatch(
  args: string[],
  stdin: string,
  extraEnv: Record<string, string> = {},
) {
  return spawnSync('node', [RUNNER, ...args], {
    input: stdin,
    encoding: 'utf8',
    env: {
      ...process.env,
      CLAUDE_PLUGIN_ROOT: tmpRoot,
      ECC_HOOK_PROFILE: 'standard',
      ...extraEnv,
    },
  })
}

// Written verbatim (no dynamic interpolation) into generated fixture module
// source below — CodeQL's js/bad-code-sanitization flags JSON.stringify()
// used as a code-construction sanitizer even when the interpolated value is
// this file's own hardcoded constant; a static literal sidesteps the pattern
// entirely instead of relying on a sanitizer CodeQL doesn't recognize as safe
// for this sink.
const BLOCK_LITERAL = "'{\"decision\":\"block\",\"reason\":\"gate says no\"}'"

beforeAll(() => {
  tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'rwf-await-'))
})
afterAll(() => {
  fs.rmSync(tmpRoot, { recursive: true, force: true })
})

describe('run-with-flags async run() is awaited', () => {
  it('honors an async run() blocking decision (not swallowed to exit 0)', () => {
    const rel = writeFixture(
      'async-block.js',
      `module.exports = { run: async () => ({ exitCode: 2, stdout: ${BLOCK_LITERAL} }) };`,
    )
    const r = runDispatch(['pre:test-async', rel, 'standard'], '{"tool":"Bash"}')
    expect(r.status).toBe(2)
    expect(r.stdout).toContain('"decision":"block"')
  })

  it('still honors a sync run() blocking decision', () => {
    const rel = writeFixture(
      'sync-block.js',
      `module.exports = { run: () => ({ exitCode: 2, stdout: ${BLOCK_LITERAL} }) };`,
    )
    const r = runDispatch(['pre:test-sync', rel, 'standard'], '{"tool":"Bash"}')
    expect(r.status).toBe(2)
    expect(r.stdout).toContain('"decision":"block"')
  })

  it('preserves the hookModule receiver for a this-using method run()', () => {
    // run() reads this.blockCode; if the runner called run() as a bare
    // function the receiver would be lost and this.blockCode undefined.
    const rel = writeFixture(
      'this-method.js',
      `module.exports = { blockCode: 2, run() { return { exitCode: this.blockCode, stdout: ${BLOCK_LITERAL} }; } };`,
    )
    const r = runDispatch(['pre:test-this', rel, 'standard'], '{"tool":"Bash"}')
    expect(r.status).toBe(2)
    expect(r.stdout).toContain('"decision":"block"')
  })

  it('fail-CLOSES for gates when an async run() rejects (--fail-closed)', () => {
    const rel = writeFixture(
      'async-throw.js',
      `module.exports = { run: async () => { throw new Error('boom'); } };`,
    )
    const r = runDispatch(
      ['pre:test-throw', rel, 'standard', '--fail-closed'],
      '{"tool":"Bash"}',
    )
    expect(r.status).toBe(2)
  })
})

describe('run-with-flags missing-hookId dispatch path', () => {
  it('fail-CLOSES (exit 2) for a --fail-closed gate with no hookId', () => {
    // No hookId/scriptRelPath args; only the gate flag.
    const r = runDispatch(['--fail-closed'], '{"tool":"Bash"}')
    expect(r.status).toBe(2)
  })

  it('fail-OPENS (exit 0) for an advisory dispatch with no hookId', () => {
    const r = runDispatch([], '{"tool":"Bash"}')
    expect(r.status).toBe(0)
  })
})
