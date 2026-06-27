import { describe, it, expect } from 'vitest';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { unescapeInlineJs } = require('../scripts/ci/validate-hooks.js');

describe('unescapeInlineJs', () => {
  it('unescapes a single escape sequence', () => {
    expect(unescapeInlineJs('a\\nb')).toBe('a\nb');
    expect(unescapeInlineJs('a\\tb')).toBe('a\tb');
    expect(unescapeInlineJs('say \\"hi\\"')).toBe('say "hi"');
  });

  it('does NOT double-unescape an escaped backslash before n (the #219 bug)', () => {
    // Source `\\n` = escaped backslash + literal n. Must stay `\` + `n`, not
    // collapse to a newline. The old sequential .replace() chain produced a
    // newline here.
    expect(unescapeInlineJs('a\\\\nb')).toBe('a\\nb');
    expect(unescapeInlineJs('a\\\\tb')).toBe('a\\tb');
  });

  it('unescapes a real escaped backslash to one backslash', () => {
    expect(unescapeInlineJs('a\\\\b')).toBe('a\\b');
  });

  it('preserves unknown escapes verbatim', () => {
    expect(unescapeInlineJs('a\\xb')).toBe('a\\xb');
  });
});
