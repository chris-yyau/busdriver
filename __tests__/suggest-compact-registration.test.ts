import { describe, it, expect } from 'vitest';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { hookRegistersSuggestCompact } = require('../scripts/lib/suggest-compact-registration.js');

const ROOT = '/tmp/plugin';
const shell = (command: string) => hookRegistersSuggestCompact({ type: 'command', command }, ROOT);

describe('suggest-compact shell registration detection', () => {
  it('credits a plain quoted invocation', () => {
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js"')).toBe(true);
  });

  it('concatenates adjacent quoted/unquoted segments like the shell (.bak is not the hook)', () => {
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js".bak')).toBe(false);  });

  it('gives no credit for 2>&1 (hook stderr logging would corrupt its JSON stdout)', () => {
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js" 2>&1')).toBe(false);
  });

  it('ends a word at a redirection operator', () => {
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js"</dev/null')).toBe(true);
  });

  it('does not count a redirection operand as an argv word', () => {
    expect(shell('node <"/tmp/plugin/scripts/hooks/suggest-compact.js" -e ""')).toBe(false);
    expect(shell('node </dev/null\\ "/tmp/plugin/scripts/hooks/suggest-compact.js"')).toBe(false);
  });

  it('gives no credit when an escaping backslash changes the word', () => {
    expect(shell('node \\${CLAUDE_PLUGIN_ROOT}/scripts/hooks/suggest-compact.js')).toBe(false);
    expect(shell('node "\\${CLAUDE_PLUGIN_ROOT}/scripts/hooks/suggest-compact.js"')).toBe(false);
    expect(shell('node "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/suggest-compact.js"')).toBe(true);
  });

  it('credits the documented run-with-flags registration', () => {
    expect(shell('node "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/run-with-flags.js" "pre:edit-write:suggest-compact" "scripts/hooks/suggest-compact.js" "standard,strict"')).toBe(true);
  });

  it('fails closed on skipped syntax and token reinterpretation', () => {
    const hook = '"/tmp/plugin/scripts/hooks/suggest-compact.js"';
    for (const command of [
      `node <<<< /dev/null ${hook}`,
      `"node"${hook}`,
      `node ${hook} 1</dev/null`,
      `node ${hook} 2>&999`,
      `NODE_OPTIONS=--bad-option node ${hook}`,
      "node '${CLAUDE_PLUGIN_ROOT}/scripts/hooks/suggest-compact.js'",
      'node "/tmp/plugin/missing/../scripts/hooks/suggest-compact.js"',
    ]) {
      expect(shell(command)).toBe(false);
    }
  });

  it('gives no credit for mixed-quote words or unterminated quotes', () => {
    expect(shell("node '$'{CLAUDE_PLUGIN_ROOT}/scripts/hooks/suggest-compact.js")).toBe(false);
    expect(shell(`node '"/tmp/plugin/scripts/hooks/suggest-compact.js"`)).toBe(false);
  });

  it('gives no credit when substitution makes argv unknowable', () => {
    expect(shell('node <(true) "/tmp/plugin/scripts/hooks/suggest-compact.js"')).toBe(false);
    expect(shell('node $(echo) "/tmp/plugin/scripts/hooks/suggest-compact.js"')).toBe(false);
    expect(shell('node "$(echo /tmp/plugin)/scripts/hooks/suggest-compact.js"')).toBe(false);
  });

  it('keeps credit for literal parentheses inside a quoted path', () => {
    const cmd = 'node "/tmp/plugin (copy)/scripts/hooks/suggest-compact.js"';
    expect(hookRegistersSuggestCompact({ type: 'command', command: cmd }, '/tmp/plugin (copy)')).toBe(true);
    const apos = `node "/tmp/plugin's/scripts/hooks/suggest-compact.js" '(argument)'`;
    expect(hookRegistersSuggestCompact({ type: 'command', command: apos }, "/tmp/plugin's")).toBe(true);
  });

  it('rejects stdout-discarding and backgrounded forms', () => {
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js" >&2')).toBe(false);
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js" 1>&2')).toBe(false);
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js" 1<&2')).toBe(false);
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js" 2>&1-')).toBe(false);
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js" | cat')).toBe(false);
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js" &')).toBe(false);
  });

  it('credits stderr-only /dev/null redirects and rejects other targets', () => {
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js" 2>/dev/null')).toBe(true);
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js" 2>>/dev/null')).toBe(true);
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js" 2>>/tmp/x')).toBe(false);
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js" >>/dev/null')).toBe(false);
    expect(shell('node "/tmp/plugin/scripts/hooks/suggest-compact.js" 12>>/dev/null')).toBe(false);
  });

  it('rejects noisy shell trailers and keeps credit for silent ones', () => {
    const hook = 'node "/tmp/plugin/scripts/hooks/suggest-compact.js"';
    expect(shell(`${hook} ; echo noisy`)).toBe(false);
    expect(shell(`${hook} && echo noisy`)).toBe(false);
    expect(shell(`${hook} || echo noisy`)).toBe(false);
    expect(shell(`${hook} ; :`)).toBe(true);
    expect(shell(`${hook} && true`)).toBe(true);
    expect(shell(`${hook} || exit 1`)).toBe(true);
  });
});
