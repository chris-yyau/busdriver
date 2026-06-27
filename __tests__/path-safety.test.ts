import { describe, it, expect, afterEach, vi } from 'vitest';
import { createRequire } from 'node:module';
import * as os from 'node:os';
import * as path from 'node:path';

const require = createRequire(import.meta.url);
// Use the CJS `fs` object — the same reference path-safety.js holds — so spies
// are visible to it (ESM namespace imports are non-configurable and cannot be spied).
const fs = require('fs');
const { safeRealpath, isWithinRoot } = require('../scripts/lib/path-safety.js');

afterEach(() => {
  vi.restoreAllMocks();
});

describe('safeRealpath fail-closed behavior (#220)', () => {
  it('falls back to the resolved path for a not-yet-existing path (ENOENT)', () => {
    const ghost = path.join(os.tmpdir(), 'ps-does-not-exist-xyz', 'child');
    expect(safeRealpath(ghost)).toBe(path.resolve(ghost));
  });

  it('throws instead of returning an unresolved path when realpath fails on an existing path (EACCES/ELOOP)', () => {
    const err = Object.assign(new Error('mocked'), { code: 'EACCES' });
    vi.spyOn(fs, 'realpathSync').mockImplementation(() => {
      throw err;
    });
    expect(() => safeRealpath('/some/existing/path')).toThrow();
  });
});

describe('isWithinRoot', () => {
  it('denies (returns false) when an existing path cannot be canonicalized', () => {
    const err = Object.assign(new Error('mocked'), { code: 'ELOOP' });
    vi.spyOn(fs, 'realpathSync').mockImplementation(() => {
      throw err;
    });
    // Without the fix this could return true on an unresolved path.
    expect(isWithinRoot('/root/child', '/root')).toBe(false);
  });

  it('detects a real symlink escape out of the root', () => {
    const base = fs.mkdtempSync(path.join(os.tmpdir(), 'ps-'));
    try {
      const root = path.join(base, 'root');
      const outside = path.join(base, 'outside');
      fs.mkdirSync(root);
      fs.mkdirSync(outside);
      const link = path.join(root, 'escape');
      fs.symlinkSync(outside, link); // root/escape -> ../outside

      expect(isWithinRoot(path.join(root, 'inside.txt'), root)).toBe(true);
      expect(isWithinRoot(path.join(link, 'pwned.txt'), root)).toBe(false);
    } finally {
      fs.rmSync(base, { recursive: true, force: true });
    }
  });
});
