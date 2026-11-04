// __tests__/ultra-oracle-snippets.test.ts — spec §11 "Snippet harness (vitest)".
// Each snippet file is one expression. It is evaluated in a fresh vm context whose
// location/document/fetch/crypto are mocks. Timers and Date are vitest fake timers,
// so 38 s polls run instantly.
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { readFileSync } from 'node:fs'
import { webcrypto, createHash } from 'node:crypto'
import vm from 'node:vm'
import path from 'node:path'

const DIR = path.join(__dirname, '../scripts/hooks/ultra-oracle-child')
const TAG = '0123456789abcdef'
const ID = '6a1f0c2e-1111-4222-8333-0000000c0de0'
const GRAMMAR = /^(READY|ATTACHED|SENT|UORA_ID [0-9a-f-]{36}|NOID|PENDING|DONE|SAVED [0-9]+ [0-9a-f]{64}|ARCHIVED|ERR [a-z0-9_-]+( [0-9]{3})?)$/
const src = (name: string) => readFileSync(path.join(DIR, `${name}.js`), 'utf8').split('__UORA_TAG__').join(TAG)

type Ctx = Record<string, unknown>
async function run(name: string, ctx: Ctx): Promise<string> {
  const sandbox = vm.createContext({
    Date, setTimeout, clearTimeout, AbortController, TextEncoder, Blob,
    crypto: webcrypto, URL: { createObjectURL: () => 'blob:x' }, ...ctx,
  })
  const p = vm.runInContext(src(name), sandbox) as Promise<string>
  await vi.runAllTimersAsync()
  const out = await p
  expect(out).toMatch(GRAMMAR)
  return out
}

const HOME = { origin: 'https://chatgpt.com', pathname: '/' }
const CONV = { origin: 'https://chatgpt.com', pathname: `/c/${ID}` }

interface DomOpts { model?: string; composer?: boolean; focusTakes?: boolean; insertTakes?: boolean;
  send?: 'enabled' | 'disabled' | 'none' | 'outside'; removes?: string[]; progress?: boolean }
function dom(o: DomOpts = {}) {
  const calls = { focus: 0, insert: 0, click: 0, download: [] as string[] }
  const sendBtn = { disabled: o.send === 'disabled', click: () => { calls.click++ } }
  const form = {
    querySelector: (s: string) =>
      s === 'button[aria-label="Send"]' ? (o.send === 'enabled' || o.send === 'disabled' ? sendBtn : null)
      : s === '[role=progressbar]' ? (o.progress ? {} : null) : null,
    querySelectorAll: (s: string) =>
      s === 'button[aria-label^="Remove "]' ? (o.removes ?? []).map((n) => ({ getAttribute: () => `Remove ${n}` })) : [],
  }
  const doc: Record<string, unknown> = { activeElement: null, body: { appendChild: () => {} } }
  const ed = {
    textContent: '',
    closest: (s: string) => (s === 'form' ? form : null),
    focus: () => { calls.focus++; if (o.focusTakes !== false) doc.activeElement = ed },
  }
  doc.querySelector = (s: string) =>
    s === '.ProseMirror' ? (o.composer === false ? null : ed)
    : s === 'button[aria-label="Select ChatGPT model"]' ? (o.model === undefined ? null : { textContent: o.model })
    : s === 'button[aria-label="Send"]' ? (o.send === 'outside' ? sendBtn : null) : null
  doc.execCommand = (_c: string, _u: boolean, t: string) => { calls.insert++; if (o.insertTakes !== false) ed.textContent = t; return true }
  doc.createElement = () => { const a: Record<string, unknown> = { remove: () => {} }; a.click = () => { calls.download.push(String(a.download)) }; return a }
  return { doc, calls }
}

beforeEach(() => { vi.useFakeTimers({ toFake: ['setTimeout', 'clearTimeout', 'Date'] }) })
afterEach(() => { vi.useRealTimers() })

describe('J-home', () => {
  it('READY on the home composer with Pro', async () => {
    expect(await run('j-home', { location: HOME, document: dom({ model: 'Thinking effort / Pro' }).doc })).toBe('READY')
  })
  it('ERR pro on a non-Pro model label', async () => {
    expect(await run('j-home', { location: HOME, document: dom({ model: 'Thinking effort / Standard' }).doc })).toBe('ERR pro')
  })
  it('ERR pro when the model control is missing', async () => {
    expect(await run('j-home', { location: HOME, document: dom({}).doc })).toBe('ERR pro')
  })
  it('ERR not-home off the home path', async () => {
    expect(await run('j-home', { location: CONV, document: dom({ model: 'Pro' }).doc })).toBe('ERR not-home')
  })
  it('ERR origin on another origin', async () => {
    expect(await run('j-home', { location: { origin: 'https://evil.example', pathname: '/' }, document: dom({ model: 'Pro' }).doc })).toBe('ERR origin')
  })
  it('a throwing document still yields a grammar line', async () => {
    const doc = { querySelector: () => { throw new Error('page text that must not leak') } }
    expect(await run('j-home', { location: HOME, document: doc })).toBe('ERR schema')
  })
})

describe('J-attached', () => {
  const me = `uora-${TAG}.txt`
  it('ATTACHED with the finished chip, an enabled Send and no progressbar', async () => {
    expect(await run('j-attached', { location: HOME, document: dom({ removes: [me], send: 'enabled' }).doc })).toBe('ATTACHED')
  })
  it('PENDING after 38 s with no chip', async () => {
    expect(await run('j-attached', { location: HOME, document: dom({ send: 'enabled' }).doc })).toBe('PENDING')
  })
  it('PENDING while the upload is still in progress', async () => {
    expect(await run('j-attached', { location: HOME, document: dom({ removes: [me], send: 'enabled', progress: true }).doc })).toBe('PENDING')
  })
  it('PENDING while Send is disabled (failed chip)', async () => {
    expect(await run('j-attached', { location: HOME, document: dom({ removes: [me], send: 'disabled' }).doc })).toBe('PENDING')
  })
  it("ERR upload on ChatGPT's renamed copy (E19)", async () => {
    expect(await run('j-attached', { location: HOME, document: dom({ removes: [`uora-${TAG}(1).txt`], send: 'enabled' }).doc })).toBe('ERR upload')
  })
})

describe('J-send', () => {
  const S = 'Follow the instructions in the attached file.'
  it('the happy path clicks only the in-form Send button', async () => {
    const d = dom({ send: 'enabled' })
    expect(await run('j-send', { location: HOME, document: d.doc })).toBe('SENT')
    expect(d.calls).toMatchObject({ focus: 1, insert: 1, click: 1 })
  })
  it.each([
    ['no composer', { composer: false, send: 'enabled' } as DomOpts, 'ERR focus'],
    ['focus not taken', { focusTakes: false, send: 'enabled' } as DomOpts, 'ERR focus'],
    ['inserted text differs', { insertTakes: false, send: 'enabled' } as DomOpts, 'ERR focus'],
    ['no Send button', { send: 'none' } as DomOpts, 'ERR send'],
    ['a disabled Send button', { send: 'disabled' } as DomOpts, 'ERR send'],
    ['a Send button outside the form only', { send: 'outside' } as DomOpts, 'ERR send'],
  ])('%s', async (_n, o, want) => {
    const d = dom(o)
    expect(await run('j-send', { location: HOME, document: d.doc })).toBe(want)
    expect(d.calls.click).toBe(0)
  })
  it('a wrong origin returns ERR origin with zero focus, insert or click calls', async () => {
    const d = dom({ send: 'enabled' })
    expect(await run('j-send', { location: { origin: 'https://evil.example', pathname: '/' }, document: d.doc })).toBe('ERR origin')
    expect(d.calls).toMatchObject({ focus: 0, insert: 0, click: 0 })
  })
  it('a wrong pathname returns ERR not-home with zero focus, insert or click calls', async () => {
    const d = dom({ send: 'enabled' })
    expect(await run('j-send', { location: CONV, document: d.doc })).toBe('ERR not-home')
    expect(d.calls).toMatchObject({ focus: 0, insert: 0, click: 0 })
  })
  it('inserts exactly the fixed sentence', async () => {
    let got = ''
    const d = dom({ send: 'enabled' }); const ex = d.doc.execCommand as (c: string, u: boolean, t: string) => boolean
    d.doc.execCommand = (c: string, u: boolean, t: string) => { got = t; return ex(c, u, t) }
    await run('j-send', { location: HOME, document: d.doc })
    expect(got).toBe(S)
  })
})

describe('J-id', () => {
  it('UORA_ID once the path is /c/<uuid>', async () => {
    expect(await run('j-id', { location: CONV, document: {} })).toBe(`UORA_ID ${ID}`)
  })
  it('NOID after 30 s on the home path', async () => {
    expect(await run('j-id', { location: HOME, document: {} })).toBe('NOID')
  })
})

describe('containment hygiene', () => {
  it('no snippet names a hook decision key or an exit code (tests/test-node-hook-containment.sh)', () => {
    for (const n of ['j-home', 'j-attached', 'j-send', 'j-id', 'j-poll', 'j-get', 'j-archive']) {
      let body = ''
      try { body = src(n) } catch { continue } // the Task 3 files may not exist yet
      expect(body).not.toMatch(/\bpermissionDecision\b|\bdecision\b|process\.exit|exitCode/)
    }
  })
})

export { run, dom, GRAMMAR, HOME, CONV, TAG, ID, createHash }
