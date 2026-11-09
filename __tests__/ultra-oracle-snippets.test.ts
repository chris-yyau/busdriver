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
  send?: 'enabled' | 'disabled' | 'none' | 'outside'; removes?: string[]; progress?: boolean; draft?: string }
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
    textContent: o.draft ?? '',
    closest: (s: string) => (s === 'form' ? form : null),
    focus: () => { calls.focus++; if (o.focusTakes !== false) doc.activeElement = ed },
  }
  doc.querySelector = (s: string) =>
    s === '.ProseMirror' ? (o.composer === false ? null : ed)
    : s === 'button[aria-label="Select ChatGPT model"]' ? (o.model === undefined ? null : { textContent: o.model })
    : s === 'button[aria-label="Send"]' ? (o.send === 'outside' ? sendBtn : null) : null
  doc.execCommand = (c: string, _u: boolean, t: string) => {
    if (c === 'insertText') { calls.insert++; if (o.insertTakes !== false) ed.textContent += t; else ed.textContent += 'X' }
    else if (c === 'delete') ed.textContent = ''
    return true
  }
  doc.createElement = () => { const a: Record<string, unknown> = { remove: () => {} }; a.click = () => { calls.download.push(String(a.download)) }; return a }
  return { doc, calls, ed }
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
  it('a leftover composer draft -> ERR draft with no insert, no click, and the draft untouched (live r1)', async () => {
    const d = dom({ send: 'enabled', draft: 'someone else\'s draft' })
    expect(await run('j-send', { location: HOME, document: d.doc })).toBe('ERR draft')
    expect(d.calls).toMatchObject({ insert: 0, click: 0 })
    expect(d.ed.textContent).toBe('someone else\'s draft')
  })
  it("the previous consult's own sentence left as a draft is cleared, then sent once (live r1)", async () => {
    const d = dom({ send: 'enabled', draft: S })
    expect(await run('j-send', { location: HOME, document: d.doc })).toBe('SENT')
    expect(d.calls).toMatchObject({ insert: 1, click: 1 })
    expect(d.ed.textContent).toBe(S)
  })
  it.each([
    ['inserted text differs', { insertTakes: false, send: 'enabled' } as DomOpts, 'ERR focus'],
    ['a disabled Send button', { send: 'disabled' } as DomOpts, 'ERR send'],
  ])('%s after inserting -> %s and the sentence is removed again', async (_n, o, want) => {
    const d = dom(o)
    expect(await run('j-send', { location: HOME, document: d.doc })).toBe(want)
    expect(d.ed.textContent).toBe('')
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

interface Node { id: string; parent: string | null; children: string[]; message: unknown }
function msg(role: string, ct: string, extra: Record<string, unknown> = {}) {
  return { id: '', author: { role }, content: { content_type: ct, parts: ['x'] }, status: 'finished_successfully', metadata: {}, ...extra }
}
// root(null) <- user(attachment) <- thoughts <- intermediate assistant text <- final assistant text  (E7/E19 shape)
function conv(o: { final?: Record<string, unknown>; attach?: string; extraUser?: boolean; hiddenCtx?: boolean; currentIntermediate?: boolean; followUp?: boolean } = {}) {
  const m: Record<string, Node> = {}
  const add = (id: string, parent: string | null, message: unknown) => { m[id] = { id, parent, children: [], message }; if (parent) m[parent].children.push(id) }
  add('root', null, null)
  let top = 'root'
  if (o.extraUser) { add('u0', top, msg('user', 'text')); add('a0', 'u0', msg('assistant', 'text', { end_turn: true })); top = 'a0' }
  if (o.hiddenCtx) { add('ctx', top, msg('user', 'user_editable_context', { metadata: { is_visually_hidden_from_conversation: true } })); top = 'ctx' }
  add('u1', top, msg('user', 'text', { metadata: { attachments: [{ name: o.attach ?? `uora-${TAG}.txt` }] } }))
  add('t1', 'u1', msg('assistant', 'thoughts'))
  add('a1', 't1', msg('assistant', 'text'))
  add('a2', 'a1', msg('assistant', 'text', { end_turn: true, metadata: { model_slug: 'gpt-6-pro' }, content: { content_type: 'text', parts: ['Verdict: ', 'sound — 結論 😀'] }, ...o.final }))
  // followUp: the chat was continued after the answer; a visible user turn below a2 is current_node
  if (o.followUp) add('u2', 'a2', msg('user', 'text'))
  return { mapping: m, current_node: o.followUp ? 'u2' : o.currentIntermediate ? 'a1' : 'a2' }
}
type Resp = { status: number; body?: unknown; hang?: boolean; throws?: boolean }
function fetchMock(conversation: Resp, extra: { session?: Resp; patch?: Resp } = {}) {
  const log: { url: string; method: string }[] = []
  const f = (url: string, init: { method?: string; signal: AbortSignal }) => {
    log.push({ url, method: init.method ?? 'GET' })
    const r = url === '/api/auth/session' ? (extra.session ?? { status: 200, body: { accessToken: 'tok' } })
      : init.method === 'PATCH' ? (extra.patch ?? { status: 200, body: {} }) : conversation
    if (r.throws) return Promise.reject(new TypeError('Failed to fetch'))
    if (r.hang) return new Promise((_, rej) => init.signal.addEventListener('abort', () => rej(new Error('aborted'))))
    return Promise.resolve({ status: r.status, json: async () => { if (r.body === undefined) throw new SyntaxError('bad json'); return r.body } })
  }
  return { f, log }
}
function getCtx(c: Resp, extra = {}) {
  const fm = fetchMock(c, extra)
  let blob: Blob | null = null
  const d = dom({})
  return { fm, d, ctx: { location: CONV, document: d.doc, fetch: fm.f, URL: { createObjectURL: (b: Blob) => { blob = b; return 'blob:x' } } }, blob: () => blob }
}

describe('J-poll', () => {
  it('DONE on a finished final turn', async () => {
    expect(await run('j-poll', getCtx({ status: 200, body: conv() }).ctx)).toBe('DONE')
  })
  it('DONE on a terminal but unbound turn (wrong model) — J-get fails it fast', async () => {
    expect(await run('j-poll', getCtx({ status: 200, body: conv({ final: { metadata: { model_slug: 'gpt-6' } } }) }).ctx)).toBe('DONE')
  })
  it('PENDING while only the intermediate assistant text exists', async () => {
    expect(await run('j-poll', getCtx({ status: 200, body: conv({ currentIntermediate: true }) }).ctx)).toBe('PENDING')
  })
  it('PENDING when end_turn is set without a finished status', async () => {
    expect(await run('j-poll', getCtx({ status: 200, body: conv({ final: { status: 'in_progress' } }) }).ctx)).toBe('PENDING')
  })
  it.each([
    [401, 'ERR auth 401'], [403, 'ERR auth 403'], [404, 'ERR gone'], [408, 'PENDING'], [429, 'ERR rate 429'],
    [400, 'ERR schema 400'], [422, 'ERR schema 422'], [500, 'ERR server 500'], [503, 'ERR server 503'], [302, 'ERR schema 302'],
  ])('HTTP %i -> %s', async (status, want) => {
    expect(await run('j-poll', getCtx({ status, body: {} }).ctx)).toBe(want)
  })
  it('a 200 with malformed JSON -> ERR schema', async () => {
    expect(await run('j-poll', getCtx({ status: 200 }).ctx)).toBe('ERR schema')
  })
  it('a 200 with missing fields -> ERR schema', async () => {
    expect(await run('j-poll', getCtx({ status: 200, body: { mapping: {} } }).ctx)).toBe('ERR schema')
  })
  it('a 200 whose current message lacks author or content -> ERR schema, not PENDING', async () => {
    expect(await run('j-poll', getCtx({ status: 200, body: { mapping: { a: { message: {} } }, current_node: 'a' } }).ctx)).toBe('ERR schema')
    expect(await run('j-poll', getCtx({ status: 200, body: { mapping: { a: { message: { author: { role: 'assistant' } } } }, current_node: 'a' } }).ctx)).toBe('ERR schema')
    expect(await run('j-poll', getCtx({ status: 200, body: { mapping: { a: { message: { author: {}, content: {} } } }, current_node: 'a' } }).ctx)).toBe('ERR schema')
  })
  it('a hung conversation fetch is aborted at its budget and J-poll reports PENDING (live r1)', async () => {
    expect(await run('j-poll', getCtx({ status: 200, hang: true }).ctx)).toBe('PENDING')
  })
  it('a hung session fetch also reports PENDING from J-poll', async () => {
    expect(await run('j-poll', getCtx({ status: 200, body: conv() }, { session: { status: 200, hang: true } }).ctx)).toBe('PENDING')
  })
  it('J-get keeps a hung fetch terminal: ERR timeout, no download', async () => {
    const g = getCtx({ status: 200, hang: true })
    expect(await run('j-get', g.ctx)).toBe('ERR timeout')
    expect(g.d.calls.download).toHaveLength(0)
  })
  it('a rejected fetch -> ERR network', async () => {
    expect(await run('j-poll', getCtx({ status: 200, throws: true }).ctx)).toBe('ERR network')
  })
  it('an origin mismatch -> ERR origin, no fetch', async () => {
    const g = getCtx({ status: 200, body: conv() })
    expect(await run('j-poll', { ...g.ctx, location: { origin: 'https://evil.example', pathname: CONV.pathname } })).toBe('ERR origin')
    expect(g.fm.log).toHaveLength(0)
  })
})

describe('J-get', () => {
  it('SAVED with the UTF-8 byte count and SHA-256 of exactly the downloaded bytes (CJK + non-BMP)', async () => {
    const g = getCtx({ status: 200, body: conv() })
    const out = await run('j-get', g.ctx)
    const bytes = new Uint8Array(await (g.blob() as Blob).arrayBuffer())
    expect(out).toBe(`SAVED ${bytes.length} ${createHash('sha256').update(bytes).digest('hex')}`)
    const obj = JSON.parse(new TextDecoder().decode(bytes))
    expect(Object.keys(obj).sort()).toEqual(['assistant_message_id', 'attachment', 'content_type', 'end_turn', 'id', 'model', 'role', 'status', 'tag', 'text', 'user_message_id'])
    expect(obj).toMatchObject({ tag: TAG, id: ID, text: 'Verdict: sound — 結論 😀', attachment: `uora-${TAG}.txt`, model: 'gpt-6-pro' })
    expect(g.d.calls.download).toEqual([`uora-${TAG}.json`])
  })
  it.each([
    ['an intermediate assistant node', { currentIntermediate: true }, 'ERR binding'],
    ['a wrong attachment ancestry', { attach: 'uora-ffffffffffffffff.txt' }, 'ERR binding'],
    ['a non-Pro model', { final: { metadata: { model_slug: 'gpt-6' } } }, 'ERR binding'],
    ['a final node without end_turn', { final: { end_turn: undefined } }, 'ERR binding'],
    ['an extra visible user turn (continued chat)', { extraUser: true }, 'ERR binding'],
    ['non-string parts', { final: { content: { content_type: 'text', parts: ['a', { x: 1 }] } } }, 'ERR schema'],
  ])('%s -> %s', async (_n, o, want) => {
    const g = getCtx({ status: 200, body: conv(o as never) })
    expect(await run('j-get', g.ctx)).toBe(want)
    expect(g.d.calls.download).toHaveLength(0)
  })
  it('a hidden user_editable_context node above the user message still binds', async () => {
    expect(await run('j-get', getCtx({ status: 200, body: conv({ hiddenCtx: true }) }).ctx)).toMatch(/^SAVED /)
  })
  it('a throwing crypto.subtle.digest still yields a grammar line', async () => {
    const g = getCtx({ status: 200, body: conv() })
    expect(await run('j-get', { ...g.ctx, crypto: { subtle: { digest: () => { throw new Error('leak me') } } } })).toBe('ERR schema')
  })
  it('a throwing anchor click still yields a grammar line', async () => {
    const g = getCtx({ status: 200, body: conv() })
    const doc = { ...g.d.doc, createElement: () => ({ click: () => { throw new Error('leak me') }, remove: () => {} }) }
    expect(await run('j-get', { ...g.ctx, document: doc })).toBe('ERR schema')
  })
})

describe('J-archive', () => {
  it('ARCHIVED after a PATCH {is_archived:true}', async () => {
    const g = getCtx({ status: 200, body: conv() })
    expect(await run('j-archive', g.ctx)).toBe('ARCHIVED')
    expect(g.fm.log.filter((c) => c.method === 'PATCH')).toHaveLength(1)
  })
  it('a wrong attachment tag sends no PATCH', async () => {
    const g = getCtx({ status: 200, body: conv({ attach: 'uora-ffffffffffffffff.txt' }) })
    expect(await run('j-archive', g.ctx)).toBe('ERR binding')
    expect(g.fm.log.filter((c) => c.method === 'PATCH')).toHaveLength(0)
  })
  it('a continued existing conversation archives nothing', async () => {
    const g = getCtx({ status: 200, body: conv({ extraUser: true }) })
    expect(await run('j-archive', g.ctx)).toBe('ERR binding')
    expect(g.fm.log.filter((c) => c.method === 'PATCH')).toHaveLength(0)
  })
  it('a chat continued after the answer (a follow-up user turn at current_node) archives nothing', async () => {
    const g = getCtx({ status: 200, body: conv({ followUp: true }) })
    expect(await run('j-archive', g.ctx)).toBe('ERR binding')
    expect(g.fm.log.filter((c) => c.method === 'PATCH')).toHaveLength(0)
  })
  it('a node with no parent field (not an explicit null root) is malformed: no SAVED, no PATCH', async () => {
    const c = conv(); delete (c.mapping.u1 as Partial<Node>).parent
    const g = getCtx({ status: 200, body: c })
    expect(await run('j-archive', g.ctx)).toBe('ERR schema')
    expect(g.fm.log.filter((x) => x.method === 'PATCH')).toHaveLength(0)
    const c2 = conv(); delete (c2.mapping.u1 as Partial<Node>).parent
    const g2 = getCtx({ status: 200, body: c2 })
    expect(await run('j-get', g2.ctx)).toBe('ERR schema')
    expect(g2.d.calls.download).toHaveLength(0)
  })
  it('a non-Pro answer at current_node archives nothing', async () => {
    const g = getCtx({ status: 200, body: conv({ final: { metadata: { model_slug: 'gpt-6' } } }) })
    expect(await run('j-archive', g.ctx)).toBe('ERR binding')
    expect(g.fm.log.filter((c) => c.method === 'PATCH')).toHaveLength(0)
  })
  it('a failed PATCH -> ERR archive <code>', async () => {
    expect(await run('j-archive', getCtx({ status: 200, body: conv() }, { patch: { status: 500 } }).ctx)).toBe('ERR archive 500')
  })
})

describe('fetch helper block', () => {
  it('is byte-identical in j-poll, j-get and j-archive', () => {
    const block = (n: string) => { const s = src(n); return s.slice(s.indexOf('// ---- uora fetch helpers'), s.indexOf('// ---- end uora fetch helpers')) }
    expect(block('j-get')).toBe(block('j-poll'))
    expect(block('j-archive')).toBe(block('j-poll'))
    expect(block('j-poll').length).toBeGreaterThan(500)
  })
})

// The r1 fixtures already carry TAG and ID, so the shared run()/getCtx() replay them unchanged.
describe('live fixtures (Task 7)', () => {
  const FX = path.join(__dirname, '../tests/fixtures/ultra-oracle')
  const live = () => JSON.parse(readFileSync(path.join(FX, 'mapping-live.json'), 'utf8'))
  const userId = (j: { mapping: Record<string, { message?: { author?: { role?: string } } }> }) =>
    Object.keys(j.mapping).find((k) => j.mapping[k].message?.author?.role === 'user')!
  it('the full live mapping binds unmodified', async () => {
    expect(await run('j-get', getCtx({ status: 200, body: live() }).ctx)).toMatch(/^SAVED [0-9]+ [0-9a-f]{64}$/)
  })
  it('J-poll reports DONE on the live mapping (thoughts, code and tool nodes above the answer)', async () => {
    expect(await run('j-poll', getCtx({ status: 200, body: live() }).ctx)).toBe('DONE')
  })
  it('the live mapping with an extra visible user turn above the user message -> ERR binding', async () => {
    const j = live(); const uid = userId(j)
    j.mapping.extra = { id: 'extra', parent: j.mapping[uid].parent, children: [uid], message: { author: { role: 'user' }, content: { content_type: 'text', parts: ['old'] }, metadata: {} } }
    j.mapping[uid].parent = 'extra'
    expect(await run('j-get', getCtx({ status: 200, body: j }).ctx)).toBe('ERR binding')
  })
  it('the live mapping with a hidden user_editable_context node inserted still binds', async () => {
    const j = live(); const uid = userId(j)
    j.mapping.ctx = { id: 'ctx', parent: j.mapping[uid].parent, children: [uid], message: { author: { role: 'user' }, content: { content_type: 'user_editable_context' }, metadata: { is_visually_hidden_from_conversation: true } } }
    j.mapping[uid].parent = 'ctx'
    expect(await run('j-get', getCtx({ status: 200, body: j }).ctx)).toMatch(/^SAVED /)
  })
  it('the E7 node carries every field path §5 reads', () => {
    const n = JSON.parse(readFileSync(path.join(FX, 'node-e7.json'), 'utf8'))
    expect(n.message.author.role).toBe('assistant')
    expect(n.message.content.content_type).toBe('text')
    expect(Array.isArray(n.message.content.parts)).toBe(true)
    expect(n.message.status).toBe('finished_successfully')
    expect(n.message.end_turn).toBe(true)
    expect(n.message.metadata.model_slug).toMatch(/^gpt-[0-9]+(\.[0-9]+)*-pro$/)
    expect(typeof n.parent).toBe('string')
  })
})

export { run, dom, GRAMMAR, HOME, CONV, TAG, ID, createHash }
