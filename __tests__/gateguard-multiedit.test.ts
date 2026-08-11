/**
 * gateguard-fact-force.js — MultiEdit branch must actually gate (#615).
 *
 * A genuine MultiEdit payload carries the target at `tool_input.file_path`; each
 * `edits[]` element holds only old_string/new_string. The old code read
 * `edit.file_path` only, so the loop body never ran and every MultiEdit fell
 * through to allow — a gate that could not fire.
 *
 * STATE_DIR is captured from the environment at module load, so each case runs in
 * a subprocess with GATEGUARD_STATE_DIR pointed at a throwaway dir.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest'
import { spawnSync } from 'node:child_process'
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const HOOK = path.resolve(here, '..', 'scripts', 'hooks', 'gateguard-fact-force.js')

// Drive the exported run() the way run-with-flags.js does: feed the payload on
// stdin, print the string (allow) or the JSON result object (deny) it returns.
const DRIVER = `
  const { run } = require(process.argv[1]);
  let d = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', c => { d += c; });
  process.stdin.on('end', () => {
    const r = run(d);
    process.stdout.write(typeof r === 'string' ? r : JSON.stringify(r));
  });
`

let stateDir: string

function invoke(payload: Record<string, unknown>) {
  const res = spawnSync('node', ['-e', DRIVER, HOOK], {
    input: JSON.stringify(payload),
    encoding: 'utf8',
    env: { ...process.env, GATEGUARD_STATE_DIR: stateDir, GATEGUARD_DISABLED: '0', ECC_GATEGUARD: '1' },
  })
  expect(res.status, res.stderr).toBe(0)
  return res.stdout
}

function decisionOf(stdout: string): string {
  let parsed: any
  try {
    parsed = JSON.parse(stdout)
  } catch {
    return 'allow' // rawInput echoed back unparsed
  }
  // An allow echoes the payload back (has tool_name); a deny returns { stdout, exitCode }.
  if (typeof parsed?.stdout !== 'string') {
    return 'allow'
  }
  return JSON.parse(parsed.stdout)?.hookSpecificOutput?.permissionDecision ?? 'allow'
}

function multiEditPayload(sessionId: string, filePath: string) {
  return {
    session_id: sessionId,
    tool_name: 'MultiEdit',
    tool_input: {
      file_path: filePath,
      // Exactly the real shape: no file_path on the individual edits.
      edits: [{ old_string: 'a', new_string: 'b' }],
    },
  }
}

beforeAll(() => {
  stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'gateguard-615-'))
})

afterAll(() => {
  fs.rmSync(stateDir, { recursive: true, force: true })
})

describe('gateguard MultiEdit branch (#615)', () => {
  it('denies a first-touch MultiEdit whose path is only at the top level', () => {
    const out = invoke(multiEditPayload('s-first-touch', '/repo/src/app.ts'))
    expect(decisionOf(out)).toBe('deny')
  })

  it('allows the retry once the file has been checked in the same session', () => {
    const payload = multiEditPayload('s-retry', '/repo/src/app.ts')
    expect(decisionOf(invoke(payload))).toBe('deny')
    expect(decisionOf(invoke(payload))).toBe('allow')
  })

  it('still gates on a per-edit file_path when the top level omits it', () => {
    const out = invoke({
      session_id: 's-nested',
      tool_name: 'MultiEdit',
      tool_input: { edits: [{ file_path: '/repo/src/nested.ts', old_string: 'a', new_string: 'b' }] },
    })
    expect(decisionOf(out)).toBe('deny')
  })

  it('allows .claude settings files and payloads carrying no usable path', () => {
    expect(decisionOf(invoke(multiEditPayload('s-settings', '/repo/.claude/settings.json')))).toBe('allow')
    expect(
      decisionOf(
        invoke({
          session_id: 's-malformed',
          tool_name: 'MultiEdit',
          tool_input: { file_path: 42, edits: [{ file_path: null }, 'not-an-object'] },
        }),
      ),
    ).toBe('allow')
  })

  it('gates a file whose first touch is inside a subagent (#611)', () => {
    // agent_id / parent_tool_use_id used to short-circuit to allow on the
    // unverified premise that the parent had already gated the file.
    for (const marker of [{ agent_id: 'sub-1' }, { parent_tool_use_id: 'toolu_1' }]) {
      const out = invoke({
        ...marker,
        session_id: `s-sub-${Object.keys(marker)[0]}`,
        tool_name: 'Edit',
        tool_input: { file_path: '/repo/src/sub.ts' },
      })
      expect(decisionOf(out)).toBe('deny')
    }
  })

  it('gates a first-touch MultiEdit inside a subagent (#611)', () => {
    for (const marker of [{ agent_id: 'sub-1' }, { parent_tool_use_id: 'toolu_1' }]) {
      expect(
        decisionOf(
          invoke({
            ...marker,
            session_id: `s-sub-multiedit-${Object.keys(marker)[0]}`,
            tool_name: 'MultiEdit',
            tool_input: { file_path: '/repo/src/sub-multiedit.ts', edits: [] },
          }),
        ),
      ).toBe('deny')
    }
  })

  it('still exempts a subagent touching a file the parent already gated (#611)', () => {
    const filePath = '/repo/src/parent-gated.ts'
    // Parent gates it first...
    expect(
      decisionOf(invoke({ session_id: 's-parent', tool_name: 'Edit', tool_input: { file_path: filePath } })),
    ).toBe('deny')
    // ...then the subagent in that same session passes straight through.
    expect(
      decisionOf(
        invoke({
          session_id: 's-parent',
          agent_id: 'sub-2',
          tool_name: 'MultiEdit',
          tool_input: { file_path: filePath, edits: [{ old_string: 'a', new_string: 'b' }] },
        }),
      ),
    ).toBe('allow')
  })

  it('does not let a non-string alias mask a valid one beside it', () => {
    // A truthy non-string in the preferred alias must not shadow the usable
    // sibling — every alias is collected, then non-strings are dropped.
    expect(
      decisionOf(
        invoke({
          session_id: 's-alias-top',
          tool_name: 'MultiEdit',
          tool_input: { file_path: 42, filePath: '/repo/src/aliased.ts', edits: [] },
        }),
      ),
    ).toBe('deny')
    expect(
      decisionOf(
        invoke({
          session_id: 's-alias-edit',
          tool_name: 'MultiEdit',
          tool_input: { edits: [{ file_path: 42, filePath: '/repo/src/nested-alias.ts' }] },
        }),
      ),
    ).toBe('deny')
  })
})
