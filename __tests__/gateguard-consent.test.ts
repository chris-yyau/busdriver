/**
 * scripts/lib/gateguard-consent.js — the #616 consent resolver, in-process.
 *
 * This is the lane that attributes coverage to the new file: vitest.config.ts has
 * coverage.include ['scripts/**\/*.js'], the shell lane is uninstrumented, and the driver
 * lane runs in a spawnSync child. It owns everything needing neither the wrapper nor a
 * payload — the homeDir() guards, anyMarkerPresent() across all three of its return
 * values, ensureDirNoFollow()'s three branches, assertDirNoFollow()'s refusals, gitEnv()'s
 * key set, and module load surviving an os.userInfo that throws.
 *
 * THE SEAM: os.userInfo is patched on the CJS `node:os` module object (mutable; the ESM
 * namespace import is not) before the module under test resolves a home. The consent
 * module reads os.userInfo at call time and never caches it at module load, which is what
 * makes this work — and is why gitEnv() is a factory rather than a module-scope constant.
 *
 * Nothing here touches the operator's real home.
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import { execFileSync } from 'node:child_process'
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'

const here = path.dirname(fileURLToPath(import.meta.url))
const CONSENT = path.resolve(here, '..', 'scripts', 'lib', 'gateguard-consent.js')
const HOOK = path.resolve(here, '..', 'scripts', 'hooks', 'gateguard-fact-force.js')

const req = createRequire(import.meta.url)
const osCjs = req('node:os')
const realUserInfo = osCjs.userInfo

// GateGuard is documented POSIX-only, but this vitest lane still runs wherever a
// contributor runs `vitest`. Directory names containing a literal newline/tab are
// rejected by mkdirSync on Windows, so skip those rows there rather than failing with
// an unrelated filesystem error.
const posixOnly = process.platform === 'win32' ? it.skip : it

let tmpRoot: string
let home: string
let repo: string

/** Point the module under test at `dir` as the passwd home, freshly required. */
function consentWithHome(dir: string | (() => never)) {
  osCjs.userInfo =
    typeof dir === 'function' ? (dir as () => never) : () => ({ ...realUserInfo(), homedir: dir })
  delete req.cache[req.resolve(CONSENT)]
  return req(CONSENT)
}

beforeEach(() => {
  tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'gg-consent-'))
  home = path.join(tmpRoot, 'home')
  repo = path.join(tmpRoot, 'repo')
  fs.mkdirSync(home)
  fs.mkdirSync(repo)
  execFileSync('git', ['init', '-q'], { cwd: repo, stdio: 'ignore' })
})

afterEach(() => {
  osCjs.userInfo = realUserInfo
  delete req.cache[req.resolve(CONSENT)]
  delete req.cache[req.resolve(HOOK)]
  fs.rmSync(tmpRoot, { recursive: true, force: true })
})

function enroll(g: any) {
  const identity = g.resolveIdentity(repo)
  g.ensureDirNoFollow(g.gateguardRoot(), 0o700)
  g.ensureDirNoFollow(g.enabledDir(), 0o700)
  fs.writeFileSync(identity.markerPath, `${identity.realpath}\n`, { flag: 'wx', mode: 0o600 })
  return identity
}

describe('homeDir()', () => {
  it('throws on an empty or relative passwd home rather than building a relative marker path', () => {
    // path.join('', '.gateguard') is the RELATIVE '.gateguard', which resolves against
    // whatever cwd the process holds — an in-repository marker, the polarity trap.
    for (const bad of ['', 'relative/home', undefined, 42]) {
      const g = consentWithHome(() => ({ ...realUserInfo(), homedir: bad }) as never)
      expect(() => g.homeDir()).toThrow(/unusable passwd home/)
    }
  })

  it('follows the passwd entry, NOT the HOME environment variable', () => {
    // V15's in-process half: the whole design rests on these disagreeing.
    const poisoned = path.join(tmpRoot, 'evilhome')
    fs.mkdirSync(poisoned)
    const prevHome = process.env.HOME
    process.env.HOME = poisoned
    try {
      const g = consentWithHome(home)
      expect(g.homeDir()).toBe(home)
      expect(g.gateguardRoot().startsWith(home)).toBe(true)
      expect(g.gateguardRoot().startsWith(poisoned)).toBe(false)
    } finally {
      if (prevHome === undefined) delete process.env.HOME
      else process.env.HOME = prevHome
    }
  })
})

describe('gitEnv()', () => {
  it('returns exactly the five specified keys', () => {
    const g = consentWithHome(home)
    expect(Object.keys(g.gitEnv()).sort()).toEqual([
      'GIT_CONFIG_GLOBAL',
      'GIT_CONFIG_SYSTEM',
      'HOME',
      'LC_ALL',
      'PATH',
    ])
    expect(g.gitEnv().LC_ALL).toBe('C')
    expect(g.gitEnv().GIT_CONFIG_GLOBAL).toBe('/dev/null')
  })

  it('is a factory: HOME tracks a mid-run change, which a module-scope constant would not', () => {
    const g = consentWithHome(home)
    expect(g.gitEnv().HOME).toBe(home)
    const other = path.join(tmpRoot, 'other')
    fs.mkdirSync(other)
    osCjs.userInfo = () => ({ ...realUserInfo(), homedir: other })
    expect(g.gitEnv().HOME).toBe(other)
  })
})

describe('assertDirNoFollow() / ensureDirNoFollow()', () => {
  it('assert refuses a symlink and a non-directory, and accepts a real directory', () => {
    const g = consentWithHome(home)
    const real = path.join(tmpRoot, 'real')
    fs.mkdirSync(real)
    expect(() => g.assertDirNoFollow(real)).not.toThrow()

    const link = path.join(tmpRoot, 'link')
    fs.symlinkSync(real, link)
    expect(() => g.assertDirNoFollow(link)).toThrow(/refusing symlink/)

    const file = path.join(tmpRoot, 'afile')
    fs.writeFileSync(file, 'x')
    expect(() => g.assertDirNoFollow(file)).toThrow(/not a directory/)
  })

  it('creates <root> even when the passwd home is itself a symlink', () => {
    // /home/u -> /mnt/u and similar are real setups. An unconditional no-follow parent
    // check would refuse to create <root> there, so every state write would fail and an
    // enrolled operator would land on allowWithStateWarning() on every call. The home is
    // the trust ANCHOR, not a boundary this design defends; what must not be followed is a
    // symlink at or below <root>.
    const realHome = path.join(tmpRoot, 'realhome')
    fs.mkdirSync(realHome)
    const linkedHome = path.join(tmpRoot, 'linkedhome')
    fs.symlinkSync(realHome, linkedHome)

    const g = consentWithHome(linkedHome)
    expect(() => g.ensureDirNoFollow(g.gateguardRoot(), 0o700)).not.toThrow()
    expect(() => g.ensureDirNoFollow(g.enabledDir(), 0o700)).not.toThrow()
    expect(fs.lstatSync(path.join(realHome, '.gateguard', 'enabled')).isDirectory()).toBe(true)
  })

  it('refuses a symlinked parent whose target ALREADY contains the directory', () => {
    // The dangerous half, and the one an earlier version missed. `lstat()` does not follow the
    // FINAL component but DOES follow intermediate ones, so when <root> is a symlink and its
    // target already holds `enabled/`, lstat('<root>/enabled') reports a real, non-symlink
    // directory — the "already exists, proceed" branch accepts it and writes land in the
    // link's target. No race needed; only a pre-existing directory under the target.
    const g = consentWithHome(home)
    const victim = path.join(tmpRoot, 'victim')
    fs.mkdirSync(path.join(victim, 'enabled'), { recursive: true })
    fs.symlinkSync(victim, g.gateguardRoot())

    // Sanity: the OS really does report it as a plain directory through the link.
    expect(fs.lstatSync(g.enabledDir()).isDirectory()).toBe(true)
    expect(fs.lstatSync(g.enabledDir()).isSymbolicLink()).toBe(false)

    expect(() => g.ensureDirNoFollow(g.enabledDir(), 0o700)).toThrow(/refusing symlink/)
    // And nothing was written into the target.
    expect(fs.readdirSync(path.join(victim, 'enabled'))).toEqual([])
  })

  it('still refuses to create through a symlinked <root>, symlinked home or not', () => {
    const g = consentWithHome(home)
    const victim = path.join(tmpRoot, 'victim')
    fs.mkdirSync(victim)
    fs.symlinkSync(victim, g.gateguardRoot())
    expect(() => g.ensureDirNoFollow(g.enabledDir(), 0o700)).toThrow(/refusing symlink/)
    expect(fs.existsSync(path.join(victim, 'enabled'))).toBe(false)
  })

  it('refuses a revoke that would delete THROUGH a symlinked ancestor', () => {
    // unlinkSync does not follow a symlink at the FINAL component, so the marker itself is
    // safe — but it DOES traverse a symlinked ancestor. The documented revoke recipe runs
    // these two asserts first for exactly that reason: with a redirected .gateguard, an
    // unguarded revoke deletes a same-named file outside the GateGuard tree.
    const g = consentWithHome(home)
    const victim = path.join(tmpRoot, 'victim')
    fs.mkdirSync(path.join(victim, 'enabled'), { recursive: true })
    const id = g.resolveIdentity(repo)
    const decoy = path.join(victim, 'enabled', id.hash)
    fs.writeFileSync(decoy, 'someone else\n')
    fs.symlinkSync(victim, g.gateguardRoot())

    // The recipe's guard fires before any unlink.
    expect(() => g.assertDirNoFollow(g.gateguardRoot())).toThrow(/refusing symlink/)
    expect(fs.existsSync(decoy)).toBe(true)

    // And without the guard the traversal is real — this is what the guard prevents.
    expect(g.markerPath(repo)).toBe(path.join(g.enabledDir(), id.hash))
    expect(fs.realpathSync(g.markerPath(repo))).toBe(fs.realpathSync(decoy))
  })

  it('ensure covers all three branches — the EEXIST one is the dominant real-machine state', () => {
    const g = consentWithHome(home)
    const target = path.join(tmpRoot, 'made')

    // (a) ENOENT -> creates. An "assert then mkdir" implementation throws here.
    g.ensureDirNoFollow(target, 0o700)
    expect(fs.lstatSync(target).isDirectory()).toBe(true)

    // (b) already a real directory -> no throw. An unconditional mkdir throws EEXIST here,
    // and this is the state of every machine that has ever run GateGuard.
    expect(() => g.ensureDirNoFollow(target, 0o700)).not.toThrow()

    // (c) symlink -> refuses, and does NOT create through it.
    const victim = path.join(tmpRoot, 'victim')
    fs.mkdirSync(victim)
    const evil = path.join(tmpRoot, 'evil')
    fs.symlinkSync(victim, evil)
    expect(() => g.ensureDirNoFollow(path.join(evil, 'child'), 0o700)).toThrow(/refusing symlink/)
    expect(() => g.ensureDirNoFollow(evil, 0o700)).toThrow(/refusing symlink/)
    expect(fs.existsSync(path.join(victim, 'child'))).toBe(false)
  })
})

describe('anyMarkerPresent()', () => {
  it("returns 'absent' with no root at all", () => {
    expect(consentWithHome(home).anyMarkerPresent()).toBe('absent')
  })

  it("returns 'absent' for an empty enabled/ — the dominant unenrolled state, and silent", () => {
    const g = consentWithHome(home)
    g.ensureDirNoFollow(g.gateguardRoot(), 0o700)
    g.ensureDirNoFollow(g.enabledDir(), 0o700)
    expect(g.anyMarkerPresent()).toBe('absent')
  })

  it("returns 'absent' when enabled/ holds only non-hex entries", () => {
    const g = consentWithHome(home)
    g.ensureDirNoFollow(g.gateguardRoot(), 0o700)
    g.ensureDirNoFollow(g.enabledDir(), 0o700)
    fs.writeFileSync(path.join(g.enabledDir(), 'README'), 'not a marker')
    expect(g.anyMarkerPresent()).toBe('absent')
  })

  it("returns 'present' for one valid marker", () => {
    const g = consentWithHome(home)
    enroll(g)
    expect(g.anyMarkerPresent()).toBe('present')
  })

  it("returns 'unreadable' when every hex-named entry is type-invalid, not 'absent'", () => {
    // The operator enrolled something this process cannot use. Folding it into 'absent'
    // would silently un-gate them — the fault-into-noise defect, losing the fault.
    const g = consentWithHome(home)
    g.ensureDirNoFollow(g.gateguardRoot(), 0o700)
    g.ensureDirNoFollow(g.enabledDir(), 0o700)
    fs.mkdirSync(path.join(g.enabledDir(), 'a'.repeat(64)))
    expect(g.anyMarkerPresent()).toBe('unreadable')
  })

  it("returns 'unreadable' when the root is a symlink", () => {
    const g = consentWithHome(home)
    fs.symlinkSync(tmpRoot, g.gateguardRoot())
    expect(g.anyMarkerPresent()).toBe('unreadable')
  })
})

describe('resolveIdentity()', () => {
  it('keys on the MAIN worktree, so a linked worktree resolves the same marker (V10)', () => {
    execFileSync('git', ['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-q', '--allow-empty', '-m', 'x'], {
      cwd: repo,
      stdio: 'ignore',
    })
    const linked = path.join(tmpRoot, 'linked')
    execFileSync('git', ['worktree', 'add', '-q', '--detach', linked], { cwd: repo, stdio: 'ignore' })

    const g = consentWithHome(home)
    expect(g.resolveIdentity(linked).markerPath).toBe(g.resolveIdentity(repo).markerPath)
    // git rev-parse --show-toplevel would key these differently — that is the bad build.
    expect(fs.realpathSync(linked)).not.toBe(g.resolveIdentity(linked).realpath)
  })

  posixOnly('resolves a worktree path containing a NEWLINE (why --porcelain -z is used)', () => {
    // The design adopts `--porcelain -z` specifically so a newline in a path is handled rather
    // than declared unhandled, and the marker identity depends on parsing that framing
    // correctly — a regression here computes the wrong hash and silently turns the gate off for
    // an enrolled repository. The doc previously rested this on primary sources alone
    // (git 2.36.0 release notes, git-worktree(1)) with no row exercising it.
    const weird = path.join(tmpRoot, 'we\nird')
    fs.mkdirSync(weird)
    execFileSync('git', ['init', '-q'], { cwd: weird, stdio: 'ignore' })

    const g = consentWithHome(home)
    const id = g.resolveIdentity(weird)
    // The record must survive framing intact: no truncation at the newline.
    expect(id.mainWorktree).toContain('\n')
    expect(id.realpath).toBe(fs.realpathSync(weird))
    expect(id.hash).toMatch(/^[0-9a-f]{64}$/)

    // And the round trip must hold: enrol, then resolve again to the same marker.
    g.ensureDirNoFollow(g.gateguardRoot(), 0o700)
    g.ensureDirNoFollow(g.enabledDir(), 0o700)
    fs.writeFileSync(id.markerPath, `${id.realpath}\n`, { flag: 'wx', mode: 0o600 })
    expect(g.isEnabled(weird)).toMatchObject({ enabled: true, status: 'enabled' })
  })

  it('records the realpath, and the hash is over that same string', () => {
    const g = consentWithHome(home)
    const id = g.resolveIdentity(repo)
    expect(id.realpath).toBe(fs.realpathSync(id.mainWorktree))
    expect(id.markerPath).toBe(path.join(g.enabledDir(), id.hash))
    expect(id.hash).toMatch(/^[0-9a-f]{64}$/)
  })
})

describe('isEnabled()', () => {
  it('is OFF and silent with no marker anywhere', () => {
    expect(consentWithHome(home).isEnabled(repo)).toMatchObject({ enabled: false, status: 'absent' })
  })

  it('is OFF for a non-absolute payload cwd', () => {
    expect(consentWithHome(home).isEnabled('relative/path')).toMatchObject({
      enabled: false,
      status: 'absent',
    })
  })

  it('is ON for the enrolled repo', () => {
    const g = consentWithHome(home)
    enroll(g)
    expect(g.isEnabled(repo)).toMatchObject({ enabled: true, status: 'enabled' })
  })

  it("is OFF with status 'absent' for a non-repository cwd — not applicable, not a fault", () => {
    const g = consentWithHome(home)
    enroll(g) // marker present, so the fast path does not short-circuit
    const plain = path.join(tmpRoot, 'plain')
    fs.mkdirSync(plain)
    expect(g.isEnabled(plain)).toMatchObject({ enabled: false, status: 'absent' })
  })

  it("is OFF with status 'error' when the marker is a directory rather than a regular file", () => {
    const g = consentWithHome(home)
    const id = g.resolveIdentity(repo)
    g.ensureDirNoFollow(g.gateguardRoot(), 0o700)
    g.ensureDirNoFollow(g.enabledDir(), 0o700)
    fs.mkdirSync(id.markerPath)
    expect(g.isEnabled(repo)).toMatchObject({ enabled: false, status: 'error' })
  })

  it('is OFF for a repo enrolled only under a poisoned HOME (V15)', () => {
    const poisoned = path.join(tmpRoot, 'evilhome')
    fs.mkdirSync(poisoned)
    // Enroll under the poisoned tree...
    const gPoison = consentWithHome(poisoned)
    enroll(gPoison)
    // ...then resolve with the passwd home pointed elsewhere: still OFF.
    const g = consentWithHome(home)
    expect(g.isEnabled(repo)).toMatchObject({ enabled: false })
  })

  it('never throws, and the module still LOADS, when os.userInfo throws (V4)', () => {
    // A module-scope `HOME: homeDir()` constant would throw during require() instead —
    // and run-with-flags.js:280-284 turns a failed require into a pass-through allow.
    const g = consentWithHome(() => {
      throw new Error('no passwd entry')
    })
    expect(typeof g.isEnabled).toBe('function')
    expect(g.isEnabled(repo)).toMatchObject({ enabled: false, status: 'error' })
  })
})

describe('generated-input properties — totality and path containment', () => {
  // The design makes two absolute claims about this module: isEnabled() NEVER throws whatever
  // it is handed, and a marker path is always inside enabledDir(). Example-based rows cover the
  // shapes we thought of; these cover shapes we did not. Deterministic (a fixed corpus plus a
  // seeded LCG) so a failure is reproducible rather than a flake.
  function lcg(seed: number) {
    let s = seed >>> 0
    return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296)
  }

  const HOSTILE: any[] = [
    '', '.', '..', '/', '//', '../..', './/../', '~', '~/x',
    'relative/path', 'C:\\Windows', '\0', 'a\nb', 'a\tb', ' ', '   ',
    '/nonexistent/' + 'x'.repeat(200), '/tmp/\u0000null', '/tmp/\uFFFDbad',
    '/tmp/' + '\u00e9'.repeat(50), '/proc/self/environ', '/dev/null',
    null, undefined, 42, true, false, {}, [], () => {}, Symbol('s'), 0n,
    Number.NaN, Infinity, new Date(), Buffer.from('x'),
  ]

  it('isEnabled() never throws and always returns the structured shape', () => {
    const g = consentWithHome(home)
    const rand = lcg(20260821)
    const generated: string[] = []
    const alphabet = 'ab/.\\ \t\n\u0000\uFFFD..%$~-_0123456789'
    for (let i = 0; i < 200; i += 1) {
      let s = ''
      const len = Math.floor(rand() * 40)
      for (let j = 0; j < len; j += 1) s += alphabet[Math.floor(rand() * alphabet.length)]
      generated.push(rand() < 0.5 ? s : '/' + s)
    }
    for (const input of [...HOSTILE, ...generated]) {
      let r: any
      expect(() => { r = g.isEnabled(input as any) }, `threw on ${String(input)}`).not.toThrow()
      expect(typeof r, `bad shape for ${String(input)}`).toBe('object')
      expect(typeof r.enabled).toBe('boolean')
      expect(['enabled', 'absent', 'error']).toContain(r.status)
      // Only a real, enrolled repository may come back enabled.
      expect(r.enabled).toBe(false)
    }
  })

  posixOnly('every resolvable identity yields a marker path INSIDE enabledDir(), hex-named', () => {
    const g = consentWithHome(home)
    const rand = lcg(777)
    const dir = g.enabledDir()
    for (let i = 0; i < 25; i += 1) {
      // Repo directory names chosen to be awkward but legal on this filesystem.
      const name = ['re po', 're.po', 're-po', '..dots', 'ünïcodé', 'tab\there', 'nl\nhere'][i % 7] + i
      const repoDir = path.join(tmpRoot, 'gen', name)
      fs.mkdirSync(repoDir, { recursive: true })
      execFileSync('git', ['init', '-q'], { cwd: repoDir, stdio: 'ignore' })
      const id = g.resolveIdentity(repoDir)
      expect(path.dirname(id.markerPath), `escaped for ${name}`).toBe(dir)
      expect(path.basename(id.markerPath)).toMatch(/^[0-9a-f]{64}$/)
      expect(id.markerPath.startsWith(dir + path.sep)).toBe(true)
      expect(id.markerPath).not.toMatch(/\.\./)
    }
  })
})

describe('the no-spawn fast path (V13b) — counted, not inferred', () => {
  // V13b requires the zero-git-spawn property be OBSERVED by counting invocations rather
  // than inferred from the step-8 budget, which cannot distinguish "no spawn" from "a fast
  // spawn". This row existed in the design for two rounds with nothing implementing it.
  // Captures the OPTIONS object too, not just the command name. An earlier version
  // discarded it, which left V16's "must be observed failing against: an implementation
  // that omits `env:` entirely" unfalsifiable — asserting gitEnv()'s return value proves
  // the factory builds the right object, not that the spawn is handed it. Inheriting the
  // parent environment while writing no environment read anywhere is exactly the build
  // that would slip through, and it is the one the whole design turns on.
  function withSpawnCounter(dir: string) {
    const cp = req('node:child_process')
    const realExec = cp.execFileSync
    const calls: Array<{ file: string; opts: any }> = []
    cp.execFileSync = (file: string, args?: any, opts?: any) => {
      calls.push({ file, opts })
      return realExec(file, args, opts)
    }
    const g = consentWithHome(dir)
    return {
      g,
      calls,
      gitCalls: () => calls.filter((c) => c.file === 'git'),
      restore: () => {
        cp.execFileSync = realExec
      },
    }
  }

  it("spawns no git when the marker set is 'absent'", () => {
    const { g, gitCalls, restore } = withSpawnCounter(home)
    try {
      expect(g.isEnabled(repo)).toMatchObject({ status: 'absent' })
      expect(gitCalls()).toEqual([])
    } finally {
      restore()
    }
  })

  it("spawns no git when the marker set is 'unreadable'", () => {
    const g0 = consentWithHome(home)
    fs.symlinkSync(tmpRoot, g0.gateguardRoot())
    const { g, gitCalls, restore } = withSpawnCounter(home)
    try {
      expect(g.isEnabled(repo)).toMatchObject({ status: 'error' })
      expect(gitCalls()).toEqual([])
    } finally {
      restore()
    }
  })

  it("spawns git exactly once when a marker IS present — the property is a fast path, not a refusal", () => {
    const g0 = consentWithHome(home)
    enroll(g0)
    const { g, gitCalls, restore } = withSpawnCounter(home)
    try {
      expect(g.isEnabled(repo)).toMatchObject({ enabled: true })
      expect(gitCalls()).toHaveLength(1)
    } finally {
      restore()
    }
  })

  it('hands the git child EXACTLY the five-key positively-constructed env (V16)', () => {
    // The bad build V16 names: `env:` omitted entirely, so the child inherits the parent
    // environment — every GIT_* discovery variable the design excludes "by construction"
    // arrives anyway — while the file still contains no environment read for a grep to find.
    const g0 = consentWithHome(home)
    enroll(g0)
    const { g, gitCalls, restore } = withSpawnCounter(home)
    try {
      g.isEnabled(repo)
      const opts = gitCalls()[0].opts
      expect(opts).toBeDefined()
      expect(opts.env).toBeDefined()
      expect(Object.keys(opts.env).sort()).toEqual([
        'GIT_CONFIG_GLOBAL',
        'GIT_CONFIG_SYSTEM',
        'HOME',
        'LC_ALL',
        'PATH',
      ])
      expect(opts.env).toEqual(g.gitEnv())
      // Not merely "has five keys": the parent's own GIT_* must not reach the child.
      expect(opts.env.GIT_DIR).toBeUndefined()
      expect(opts.env.GIT_WORK_TREE).toBeUndefined()
      expect(opts.env.LC_ALL).toBe('C')
      // stderr must be piped, not discarded — the absent/error classifier reads it.
      expect(opts.stdio).toEqual(['ignore', 'pipe', 'pipe'])
    } finally {
      restore()
    }
  })
})

describe('pruneStaleFiles (5(h)) — reached only from saveState', () => {
  function hookAt(dir: string) {
    consentWithHome(dir)
    delete req.cache[req.resolve(HOOK)]
    return req(HOOK)
  }
  const payload = (sid: string) =>
    JSON.stringify({ session_id: sid, cwd: repo, tool_name: 'Edit', tool_input: { file_path: '/x/a.ts' } })

  it('removes a state file older than 2x SESSION_TIMEOUT_MS when a state write occurs', () => {
    const g = consentWithHome(home)
    enroll(g)
    const hook = hookAt(home)

    const stale = path.join(g.gateguardRoot(), 'state-sid-deadbeefdeadbeefdeadbeef.json')
    fs.mkdirSync(g.gateguardRoot(), { recursive: true })
    fs.writeFileSync(stale, JSON.stringify({ checked: [], last_active: 0 }))
    const old = Date.now() / 1000 - 3 * 60 * 60 // 3h — past the 2 x 30min threshold
    fs.utimesSync(stale, old, old)

    hook.run(payload('s-prune')) // a first-touch deny => markChecked => saveState => prune
    expect(fs.existsSync(stale)).toBe(false)
  })

  it('does NOT read the state directory at all when the gate is not enabled', () => {
    // As a module-scope IIFE this ran at require() time on every gated call, enrolled or
    // not. 5(h) makes it a called function so the unenrolled path performs no directory
    // read — observed by counting readdirSync against the state root.
    const g = consentWithHome(home)
    g.ensureDirNoFollow(g.gateguardRoot(), 0o700) // exists, but no marker => not enabled
    const root = g.gateguardRoot()

    // Patch the CJS module object, not the ESM namespace import — the latter is frozen.
    const fsCjs = req('node:fs')
    const realReaddir = fsCjs.readdirSync
    const reads: string[] = []
    fsCjs.readdirSync = (p: any, ...rest: any[]) => {
      reads.push(String(p))
      return realReaddir(p, ...rest)
    }
    try {
      const hook = hookAt(home)
      hook.run(payload('s-unenrolled'))
    } finally {
      fsCjs.readdirSync = realReaddir
    }
    expect(reads.filter((p) => p === root)).toEqual([])
  })
})

describe('the hook, driven in-process', () => {
  function hookWithHome(dir: string) {
    consentWithHome(dir)
    delete req.cache[req.resolve(HOOK)]
    return req(HOOK)
  }

  const editPayload = (sessionId: string, cwd: string, filePath = '/x/app.ts') =>
    JSON.stringify({ session_id: sessionId, cwd, tool_name: 'Edit', tool_input: { file_path: filePath } })

  function decisionOf(result: any): string {
    if (typeof result === 'string') return 'allow'
    if (typeof result?.stdout !== 'string') return 'allow'
    return JSON.parse(result.stdout)?.hookSpecificOutput?.permissionDecision ?? 'allow'
  }

  it('allows without touching the state directory when the repo is not enrolled', () => {
    const hook = hookWithHome(home)
    expect(decisionOf(hook.run(editPayload('s1', repo)))).toBe('allow')
    expect(fs.existsSync(path.join(home, '.gateguard'))).toBe(false)
  })

  it('denies the first touch and allows the retry when enrolled (V11)', () => {
    const g = consentWithHome(home)
    enroll(g)
    const hook = hookWithHome(home)
    expect(decisionOf(hook.run(editPayload('s-first', repo)))).toBe('deny')
    expect(decisionOf(hook.run(editPayload('s-first', repo)))).toBe('allow')
  })

  it('keeps two sessions apart even when their ids differ only by a folded character (V12)', () => {
    const g = consentWithHome(home)
    enroll(g)
    const hook = hookWithHome(home)
    // 'a/b' and 'a?b' both became 'a_b' under the old non-injective substitution.
    expect(decisionOf(hook.run(editPayload('a/b', repo)))).toBe('deny')
    expect(decisionOf(hook.run(editPayload('a?b', repo)))).toBe('deny')
  })

  it('allows and writes no state when the payload carries no usable session key', () => {
    const g = consentWithHome(home)
    enroll(g)
    const hook = hookWithHome(home)
    const payload = JSON.stringify({ cwd: repo, tool_name: 'Edit', tool_input: { file_path: '/x/a.ts' } })
    expect(decisionOf(hook.run(payload))).toBe('allow')
    expect(fs.readdirSync(path.join(home, '.gateguard')).filter((f) => f.startsWith('state-'))).toEqual([])
  })

  it('never prints the marker path or a multi-line cause on the error diagnostic', () => {
    // The `cause` strings are built from raw fs/exec messages and embed the marker path.
    // The diagnostic promises one line and no path; that promise is enforced, not asserted.
    const g = consentWithHome(home)
    const id = g.resolveIdentity(repo)
    g.ensureDirNoFollow(g.gateguardRoot(), 0o700)
    g.ensureDirNoFollow(g.enabledDir(), 0o700)
    fs.mkdirSync(id.markerPath) // a directory at the marker path => status 'error'

    const hook = hookWithHome(home)
    const written: string[] = []
    const realWrite = process.stderr.write.bind(process.stderr)
    ;(process.stderr as any).write = (chunk: any) => {
      written.push(String(chunk))
      return true
    }
    try {
      hook.run(editPayload('s-err', repo))
    } finally {
      ;(process.stderr as any).write = realWrite
    }

    const line = written.join('')
    expect(line).toContain('[Fact-Forcing Gate]')
    expect(line.trimEnd()).not.toContain('\n')
    expect(line).not.toContain(id.markerPath)
    expect(line).not.toContain(id.hash)
    expect(line).not.toMatch(/\.gateguard/)
  })

  it('carries no revocation recipe in the deny text (V9, 5(g))', () => {
    const g = consentWithHome(home)
    enroll(g)
    const hook = hookWithHome(home)
    const result = hook.run(editPayload('s-msg', repo))
    const reason = JSON.parse(result.stdout).hookSpecificOutput.permissionDecisionReason
    expect(reason).not.toMatch(/ECC_|GATEGUARD_|\.gateguard|gateguard-enable/)
    expect(reason).toContain('Present the facts, then retry the same operation.')
  })
})
