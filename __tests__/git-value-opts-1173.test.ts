/**
 * #1173: git global options that take a separate value (--config-env, --attr-source,
 * --shallow-file) must not hide the subcommand from the JS hooks, matching the Python
 * _GIT_VALUE_OPTS in hooks/gate-scripts/lib/gitcmd_detect.py.
 */
import { describe, it, expect } from 'vitest'
import * as path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'

const here = path.dirname(fileURLToPath(import.meta.url))
const req = createRequire(import.meta.url)
const noVerify = req(path.resolve(here, '..', 'scripts', 'hooks', 'block-no-verify.js'))
const gateguard = req(path.resolve(here, '..', 'scripts', 'hooks', 'gateguard-fact-force.js'))

const OPTS = [
  '--config-env user.name=NAME', '--attr-source HEAD', '--shallow-file /x',
  // a value word holding a quoted or escaped space must stay one word
  '-C "/a b"', "--git-dir '/a b/.git'", '-C /a\\ b', '--shallow-file "/a b"', '--shallow-file /a\\ b',
]

describe('block-no-verify: value options before the subcommand', () => {
  for (const o of OPTS) {
    it(`blocks git ${o} commit --no-verify`, () => {
      expect(noVerify.run(`git ${o} commit --no-verify -m x`).exitCode).toBe(2)
    })
  }
  it('still allows a plain commit behind the same options', () => {
    for (const o of OPTS) expect(noVerify.run(`git ${o} commit -m x`).exitCode).toBe(0)
  })
})

describe('block-no-verify: --config-env core.hooksPath is a hooks override', () => {
  for (const c of ['git --config-env core.hooksPath=HP commit -m x', 'git --config-env=core.HOOKSPATH=HP commit -m x']) {
    it(`blocks ${c}`, () => expect(noVerify.run(c).exitCode).toBe(2))
  }
})

describe('operands are not options or subcommands', () => {
  it('a subcommand-named value of a pending option is not the subcommand', () => {
    expect(noVerify.run('git --attr-source HEAD -C commit log -n 1').exitCode).toBe(0)
  })
  it('an override spelled as another option\'s value is not an override', () => {
    expect(noVerify.run('git -C --config-env=core.hooksPath=HP commit -m x').exitCode).toBe(0)
  })
  it('gateguard: push -o value text is not a short-flag cluster', () => {
    expect(gateguard.isDestructiveBash('git push -oci.note=ready\\ for\\ review')).toBe(false)
    expect(gateguard.isDestructiveBash('git push -fo x')).toBe(true)
  })
})

describe('line continuations', () => {
  it('block-no-verify sees the subcommand across a backslash-newline', () => {
    expect(noVerify.run('git -C /x \\\n commit --no-verify').exitCode).toBe(2)
  })
  it('gateguard sees --hard across a backslash-newline', () => {
    expect(gateguard.isDestructiveBash('git reset \\\n--hard')).toBe(true)
  })
})

describe('gateguard isDestructiveBash: value options before the subcommand', () => {
  for (const o of OPTS) {
    it(`flags git ${o} reset --hard`, () => {
      expect(gateguard.isDestructiveBash(`git ${o} reset --hard`)).toBe(true)
    })
  }
  it('does not flag a safe subcommand behind the same options', () => {
    for (const o of OPTS) expect(gateguard.isDestructiveBash(`git ${o} status`)).toBe(false)
  })
})
