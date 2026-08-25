/**
 * scripts/ci/validate-model-routes.js — the ADR 0046 model-route contract.
 *
 * WHY THIS EXISTS: once every checked-in agent is `opus`, the sonnet-rejection branch,
 * the FABLE_ALLOWED predicate, the read-only capability check and the
 * skills/<skill>/agents discovery extension all become code with no committed exercise —
 * a later refactor or upstream sync could neuter them silently. Same argument ADR 0009
 * uses to justify tests/test-agent-effort-tiers.sh.
 *
 * THE SEAM: validateModelRoutes({ rootDir, fableAllowed }) takes both as arguments, so
 * every case runs against a mkdtemp mini-tree and the SHIPPED constants stay frozen and
 * empty. Case order matters: the allowlisted-fable PASS must be reachable before the
 * capability rejections mean anything — with an empty allowlist a fable agent is
 * rejected by the allowlist check before the capability check ever runs.
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createRequire } from 'node:module'

const require_ = createRequire(import.meta.url)
const REPO = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const { validateModelRoutes, parseTools, FABLE_ALLOWED } = require_(
  path.join(REPO, 'scripts/ci/validate-model-routes.js'),
)

let root: string

function agent(rel: string, frontmatter: string) {
  const file = path.join(root, rel)
  fs.mkdirSync(path.dirname(file), { recursive: true })
  fs.writeFileSync(file, `---\n${frontmatter}\n---\n\n# body\n`)
  return rel
}

const ok = 'tools: ["Read", "Grep", "Glob"]\neffort: high'

beforeEach(() => {
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'model-routes-'))
})
afterEach(() => {
  fs.rmSync(root, { recursive: true, force: true })
})

describe('agent metadata policy', () => {
  it('accepts opus in both discovery locations', () => {
    agent('agents/a.md', 'name: a\nmodel: opus\ntools: ["Read", "Bash"]')
    agent('skills/x/agents/b.md', 'name: b\nmodel: opus')
    expect(validateModelRoutes({ rootDir: root })).toEqual([])
  })

  it('rejects sonnet and haiku in agents/ AND in a skill-embedded agent', () => {
    agent('agents/a.md', 'name: a\nmodel: sonnet')
    agent('skills/x/agents/b.md', 'name: b\nmodel: sonnet')
    agent('agents/c.md', 'name: c\nmodel: haiku')
    const errors = validateModelRoutes({ rootDir: root })
    expect(errors).toHaveLength(3)
    expect(errors.join('\n')).toContain('skills/x/agents/b.md')
    expect(errors.join('\n')).toContain('weaker Claude tier')
  })

  it('rejects a versioned id — proving a closed whitelist, not a two-name denylist', () => {
    agent('agents/a.md', 'name: a\nmodel: claude-sonnet-5')
    expect(validateModelRoutes({ rootDir: root })).toHaveLength(1)
  })

  it('rejects a non-family, non-fable value — the case only a whitelist catches', () => {
    agent('agents/a.md', 'name: a\nmodel: gemini')
    const errors = validateModelRoutes({ rootDir: root })
    expect(errors).toHaveLength(1)
    expect(errors[0]).toContain('not an accepted model')
  })

  it('rejects a missing or empty model pin', () => {
    agent('agents/a.md', 'name: a\ntools: ["Read"]')
    agent('agents/b.md', 'name: b\nmodel:')
    const errors = validateModelRoutes({ rootDir: root })
    expect(errors).toHaveLength(2)
    expect(errors.join('\n')).toContain("missing 'model'")
  })

  it('rejects duplicate model keys instead of letting last-wins decide', () => {
    agent('agents/a.md', 'name: a\nmodel: opus\nmodel: sonnet')
    const errors = validateModelRoutes({ rootDir: root })
    expect(errors).toHaveLength(1)
    expect(errors[0]).toContain('duplicate')
  })

  it('scopes discovery: a non-agent skill file with a weak pin is ignored', () => {
    agent('skills/x/SKILL.md', 'name: x\nmodel: sonnet')
    expect(validateModelRoutes({ rootDir: root })).toEqual([])
  })
})

describe('fable allowlist and capability check', () => {
  it('rejects fable when the path is not allowlisted', () => {
    agent('agents/oracle.md', `name: oracle\nmodel: fable\n${ok}`)
    const errors = validateModelRoutes({ rootDir: root })
    expect(errors).toHaveLength(1)
    expect(errors[0]).toContain('not permitted here')
  })

  // Must pass before the rejections below carry any meaning.
  it('accepts an allowlisted fable agent with read-only tools, in both YAML forms', () => {
    for (const tools of ['tools: ["Read", "Grep", "Glob"]', 'tools: [Read, Grep, Glob]']) {
      fs.rmSync(root, { recursive: true, force: true })
      fs.mkdirSync(root, { recursive: true })
      const rel = agent('skills/x/agents/oracle.md', `name: oracle\nmodel: fable\n${tools}\neffort: high`)
      expect(validateModelRoutes({ rootDir: root, fableAllowed: [rel] })).toEqual([])
    }
  })

  it('rejects an allowlisted fable agent holding a mutation tool', () => {
    for (const tools of ['tools: ["Read", "Bash"]', 'tools: ["Write"]']) {
      fs.rmSync(root, { recursive: true, force: true })
      fs.mkdirSync(root, { recursive: true })
      const rel = agent('agents/oracle.md', `name: oracle\nmodel: fable\n${tools}\neffort: high`)
      const errors = validateModelRoutes({ rootDir: root, fableAllowed: [rel] })
      expect(errors).toHaveLength(1)
      expect(errors[0]).toContain('may not hold')
    }
  })

  it('rejects missing, empty, indented or malformed tools — absence is full access', () => {
    const cases = ['', 'tools:', 'tools:\n  - Read\n  - Grep', 'tools: ["Read"']
    for (const tools of cases) {
      fs.rmSync(root, { recursive: true, force: true })
      fs.mkdirSync(root, { recursive: true })
      const rel = agent('agents/oracle.md', `name: oracle\nmodel: fable\n${tools}\neffort: high`)
      const errors = validateModelRoutes({ rootDir: root, fableAllowed: [rel] })
      expect(errors.join('\n')).toContain("needs a single-line, parseable, non-empty 'tools:'")
    }
  })

  it('requires an explicit effort of high or below on a fable agent', () => {
    for (const effort of ['', 'effort: turbo', 'effort: xhigh', 'effort: max']) {
      fs.rmSync(root, { recursive: true, force: true })
      fs.mkdirSync(root, { recursive: true })
      const rel = agent('agents/oracle.md', `name: oracle\nmodel: fable\ntools: ["Read"]\n${effort}`)
      const errors = validateModelRoutes({ rootDir: root, fableAllowed: [rel] })
      expect(errors.join('\n')).toContain("needs an explicit 'effort:'")
    }
  })

  it('ships FABLE_ALLOWED empty, and the default path cannot be opened without a code change', () => {
    expect([...FABLE_ALLOWED]).toEqual([])
    agent('agents/oracle.md', `name: oracle\nmodel: fable\n${ok}`)
    // No fableAllowed argument => the production constant is what is consulted.
    expect(validateModelRoutes({ rootDir: root })).toHaveLength(1)
  })

  it('rejects duplicate tools/effort keys on a fable candidate', () => {
    for (const dup of ['tools: ["Read"]\ntools: ["Bash"]', 'effort: high\neffort: max']) {
      fs.rmSync(root, { recursive: true, force: true })
      fs.mkdirSync(root, { recursive: true })
      const rel = agent('agents/oracle.md', `name: oracle\nmodel: fable\ntools: ["Read"]\neffort: high\n${dup}`)
      const errors = validateModelRoutes({ rootDir: root, fableAllowed: [rel] })
      expect(errors.join('\n')).toContain('duplicate')
    }
  })

  it('parseTools rejects tokens with residual quotes or brackets', () => {
    expect(parseTools('[Read, Grep]')).toEqual(['Read', 'Grep'])
    expect(parseTools('["Read"]')).toEqual(['Read'])
    expect(parseTools('[Read, ]')).toBeNull()
    expect(parseTools('["Read"]]')).toBeNull()
  })
})

describe('CI wiring and watchdog ordering', () => {
  // readFileSync, NOT require: validate-all.js runs all validators at module scope and
  // ends in a bare process.exit, which would kill the vitest process mid-suite.
  it('is registered in validate-all.js VALIDATORS', () => {
    const src = fs.readFileSync(path.join(REPO, 'scripts/ci/validate-all.js'), 'utf-8')
    expect(src).toContain("'validate-model-routes.js'")
  })

  // ADR 0046 KD4: the inner LLM budget only means anything if it fires BEFORE the outer
  // spawn kills the hook. Both literals are read from source so a change to either side
  // breaks this rather than silently restoring the old inverted ordering.
  it('keeps LLM_TIMEOUT_MS below run-with-flags legacy spawn timeout', () => {
    const inner = fs.readFileSync(path.join(REPO, 'scripts/lib/llm-summary.js'), 'utf-8')
    const outer = fs.readFileSync(path.join(REPO, 'scripts/hooks/run-with-flags.js'), 'utf-8')
    const innerMs = Number(inner.match(/const LLM_TIMEOUT_MS = (\d+)/)?.[1])
    const outerMs = Number(outer.match(/timeout:\s*(\d+)/)?.[1])
    expect(innerMs).toBeGreaterThan(0)
    expect(outerMs).toBeGreaterThan(0)
    expect(innerMs).toBeLessThan(outerMs)
    expect(outerMs - innerMs).toBeGreaterThanOrEqual(5000)
  })
})
