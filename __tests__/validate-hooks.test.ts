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

describe('matcher-group keys', () => {
  // Claude Code warns "hooks.json: unknown keys ..." for any group key besides matcher/hooks.
  const { execFileSync, spawnSync } = require('node:child_process');
  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const validator = path.join(__dirname, '../scripts/ci/validate-hooks.js');
  const real = path.join(__dirname, '../hooks/hooks.json');

  it('accepts the shipped hooks.json', () => {
    execFileSync('node', [validator, real], { stdio: 'pipe' });
  });

  it('rejects a description key on a matcher group', () => {
    const data = JSON.parse(fs.readFileSync(real, 'utf8'));
    data.hooks.SessionStart[0].description = 'x';
    const tmp = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'vh-')), 'hooks.json');
    fs.writeFileSync(tmp, JSON.stringify(data));
    const r = spawnSync('node', [validator, tmp], { encoding: 'utf8' });
    expect(r.status).not.toBe(0);
    expect(r.stderr).toContain("SessionStart[0] has unknown key 'description'");
  });
});
