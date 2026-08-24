#!/usr/bin/env node
/**
 * Read size advisory (PreToolUse - Read)
 *
 * Fail-open advisory: when a wholesale Read targets a file verifiably over
 * ~200 lines within the bounded probe, surface that it exceeds the self-read
 * threshold and narrowing-first guidance. The probe is bounded (file cap
 * 50 MiB; at most the first 1 MiB scanned) and the threshold must be VERIFIED
 * within the scanned window — files that are larger than the cap, or whose
 * first window does not itself prove the threshold, stay silent. Silent when
 * limit/offset is set, under threshold, outside the workspace root, or on any
 * error. Never blocks, never reads file content into context.
 *
 * Intentional residual (issue #626, Council Option A): this decision-time
 * advisory intentionally performs a BOUNDED probe (open + scan, <= 1 MiB,
 * realpath-contained to the payload cwd) BEFORE the Read permission decision,
 * disclosing only a coarse existence/regularity/over-threshold predicate about
 * the model-named path. Do NOT deploy where pre-permission probing is
 * unacceptable; hook privilege MUST remain <= model privilege.
 *
 * Containment is descriptor-anchored: after opening, the kernel's own answer
 * for what path the opened fd names (macOS: system lsof, F_GETPATH-derived;
 * Linux: /proc/self/fd readlink) is compared as a STRING against the canonical
 * payload cwd — both captured at hook start, before any open, and never
 * re-resolved — so no pathname state — final component, intermediate
 * component, root swap, or ABA restore — can be raced against the fd or its
 * trust root. The fd is immutable after open. Platforms without an fd-to-path
 * primitive stay silent (fail-open); any failure of the fd probe also stays
 * silent.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { buildPreToolUseAdditionalContext } = require('./pretooluse-visible-output');
const { assertWithinTrustedRoot } = require('../lib/path-safety.js');

const MAX_STDIN = 1024 * 1024;
const THRESHOLD = 200;
const READ_CHUNK = 64 * 1024;
const MAX_SCAN_BYTES = 50 * 1024 * 1024;
const MAX_WORK_BYTES = 1024 * 1024;
const OPEN_FLAGS = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0) | (fs.constants.O_NONBLOCK || 0);
// Strict: callers must pass a string (run() guards typeof first). No
// coercion — a wrong-typed file_path must stay silent, never throw.
function isSafePath(filePath) {
  return filePath.length > 0 && !/[\x00-\x1f\x7f\u0085\u2028\u2029]/.test(filePath);
}

// Resolve <filePath> against the payload cwd (the trusted workspace root) and
// reject anything whose realpath escapes it. The hook must not become a
// side-channel that opens/scans paths the Read operation's own permission
// decision would deny. Delegates the containment boundary to the canonical
// path-safety primitive (realpath both sides, reject escapes); a missing or
// unresolvable target stays silent (fail-open advisory).
function resolveContained(filePath, cwd) {
  try {
    // nosemgrep: javascript.lang.security.audit.path-traversal.path-join-resolve-traversal.path-join-resolve-traversal -- resolve only canonicalizes against the payload cwd; assertWithinTrustedRoot enforces the realpath containment boundary on the result.
    const abs = path.resolve(cwd, filePath);
    return assertWithinTrustedRoot(abs, cwd);
  } catch {
    return null;
  }
}

// Scan up to <end> bytes of <fd> (the bounded window), counting newlines and
// tracking the last byte. Returns null when a NUL (binary marker) appears
// anywhere in the window — the window is scanned COMPLETELY so a later-chunk
// NUL is still detected before any over-threshold classification. Reads are
// bounded by <end> itself, so short reads can never push the scan past the
// work budget.
function scanWindow(fd, end, buffer) {
  let lines = 0;
  let lastByte = 0;
  let offset = 0;
  // At most one chunk per window position bounds the syscall count even under
  // pathological short reads (readSync returning 1 byte would otherwise loop
  // up to ~1M times). An iteration-capped scan has not seen the whole window,
  // so it cannot classify: the caller treats a short offset as unverified.
  const maxChunks = Math.ceil(end / READ_CHUNK);
  let chunks = 0;
  while (offset < end && chunks < maxChunks) {
    const toRead = Math.min(READ_CHUNK, end - offset);
    const read = fs.readSync(fd, buffer, 0, toRead, offset);
    if (read <= 0) break;
    if (buffer.subarray(0, read).includes(0)) return null;
    for (let i = 0; i < read; i++) {
      if (buffer[i] === 0x0a) lines++;
      lastByte = buffer[i];
    }
    offset += read;
    chunks++;
  }
  if (offset < end && chunks >= maxChunks) {
    return null;
  }
  return { lines, lastByte, offset };
}

// Kernel-derived path of an open descriptor (lsof -Fn emits n<path>). The fd
// number is the hook's own; lsof is a trusted macOS system binary at an
// absolute path. Any failure → null (fail-open: stay silent).
function fdRealPath(fd) {
  try {
    if (process.platform === 'darwin') {
      // -F0n: NUL-delimited fields — a path containing a newline stays inside
      // one field, so a forged "n<trusted-prefix>" fragment cannot be parsed
      // as a second path field.
      const out = spawnSync('/usr/sbin/lsof', ['-a', '-p', String(process.pid), '-d', String(fd), '-F0n'], {
        encoding: 'utf8',
        timeout: 2000,
      });
      if (out.status !== 0) return null;
      for (const field of (out.stdout || '').split('\0')) {
        if (field.startsWith('n')) return field.slice(1);
      }
      return null;
    }
    if (process.platform === 'linux') {
      // No " (deleted)" stripping: that suffix is a legitimate filename, and
      // an unlinked file keeps its real path prefix — the descendant check
      // still applies, and scanning a dead fd reads zero bytes.
      return fs.readlinkSync(`/proc/self/fd/${fd}`);
    }
    return null;
  } catch {
    return null;
  }
}

function countLines(openPath, cwdReal, rootStat) {
  let fd;
  try {
    // O_NOFOLLOW defends the final component against symlink swaps. The
    // load-bearing check is the descriptor-anchored containment below: the
    // kernel's canonical path for the OPENED fd must be a string descendant of
    // the canonical payload cwd. The fd is immutable after open, and the
    // kernel's path is not re-resolved — a pathname swap cannot re-anchor it.
    fd = fs.openSync(openPath, OPEN_FLAGS);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) return null;
    if (stat.size === 0) return 0;
    if (stat.size > MAX_SCAN_BYTES) return null;
    const fdPath = fdRealPath(fd);
    if (fdPath === null) return null;
    // The root's DIRECTORY identity must be unchanged since capture: a
    // rename-and-replace of the root pathname is rejected here, and an ABA
    // restore moves the fd's file out of the root string (the kernel path
    // follows the renames) — either way the probe stays inside the original
    // trusted root.
    const rootNow = fs.statSync(cwdReal);
    if (rootNow.dev !== rootStat.dev || rootNow.ino !== rootStat.ino) return null;
    // String-descendant test against the root captured at hook start. The root
    // '/' case must not become '//' (a bare-prefix comparison would reject
    // every descendant and silently disable the advisory).
    const isDescendant = fdPath === cwdReal || (fdPath.startsWith(cwdReal) && (cwdReal === path.sep || fdPath[cwdReal.length] === path.sep));
    if (!isDescendant) return null;

    const buffer = Buffer.alloc(READ_CHUNK);
    // Fixed work budget independent of newline count: at most MAX_WORK_BYTES
    // scanned (the bounded probe). Budget exhausted with the count still
    // unknown → silent; the advisory only fires on a VERIFIED over-threshold.
    const windowEnd = Math.min(stat.size, MAX_WORK_BYTES);
    const window = scanWindow(fd, windowEnd, buffer);
    if (window === null) return null;
    // Re-stat after the scan: size changes mid-scan must not feed the
    // classification (a concurrent truncation could otherwise "prove" lines
    // that were never read).
    const current = fs.fstatSync(fd);

    // Observed newlines are authoritative: the scan READ them.
    if (window.lines > THRESHOLD) return window.lines;
    // An early EOF means the window was not fully scanned (the file shrank
    // mid-scan): the window is not NUL-complete, so nothing can be classified.
    if (window.offset < windowEnd) return null;
    // The window was fully scanned; bytes beyond it are outside the probe's
    // NUL scope, so a continuing line or further bytes VERIFY a threshold+1st
    // line.
    if (window.lines === THRESHOLD && (window.lastByte !== 0x0a || window.offset < current.size)) {
      return THRESHOLD + 1;
    }
    if (window.offset < current.size) return null;
    return window.lastByte !== 0x0a ? window.lines + 1 : window.lines;
  } catch {
    return null;
  } finally {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch {
        // ignore close errors
      }
    }
  }
}

/**
 * Exportable run() for in-process execution via run-with-flags.js.
 */
function run(inputOrRaw, _options = {}) {
  let input;
  try {
    input = typeof inputOrRaw === 'string'
      ? (inputOrRaw.trim() ? JSON.parse(inputOrRaw) : {})
      : (inputOrRaw || {});
  } catch {
    return { exitCode: 0 };
  }

  const { file_path: filePath, offset, limit } = input?.tool_input || {};
  if (offset !== undefined || limit !== undefined || typeof filePath !== 'string' || !filePath || !isSafePath(filePath)) {
    return { exitCode: 0 };
  }

  const cwd = input?.cwd || process.cwd();
  // Canonicalize the trust root ONCE, before any containment or open: the
  // opened fd's kernel path is compared against THIS fixed string, so a swap
  // of cwd's own components after this point cannot re-anchor the check.
    let cwdReal;
  let rootStat;
  try {
        cwdReal = fs.realpathSync(cwd);
    const s = fs.statSync(cwdReal);
    rootStat = { dev: s.dev, ino: s.ino };
  } catch {
    return { exitCode: 0 };
  }
  const resolved = resolveContained(filePath, cwd);
  if (resolved === null) {
    return { exitCode: 0 };
  }

    const lines = countLines(resolved, cwdReal, rootStat);
  if (lines === null || lines <= THRESHOLD) {
    return { exitCode: 0 };
  }

  return {
    exitCode: 0,
    additionalContext: [
      '[Hook] The requested file exceeds the ~200-line self-read threshold.',
      '[Hook] 1) Do you need all of it? Narrow with offset/limit - free, no dispatch floor.',
      '[Hook] 2) Otherwise route to pi. Both trust gates are yours to judge, not this hook\'s.',
    ],
  };
}

module.exports = { run, countLines, isSafePath, THRESHOLD };

// Standalone stdin main only when executed directly (node pre-read-size-advisory.js).
// run-with-flags.js requires this module and calls run() in-process; unconditional
// registration would double-consume the payload and duplicate protocol output.
if (require.main === module) {
  // Byte-capped capture mirroring run-with-flags' readStdinRaw: decoded
  // String#length counts UTF-16 units, not UTF-8 bytes, so a multi-byte
  // payload could exceed the advertised cap. On truncation the captured JSON
  // is malformed by construction — run() allows (fail-open) and the echo is
  // suppressed so the hook protocol output is never a cut payload.
  const chunks = [];
  let byteLength = 0;
  let truncated = false;
  process.stdin.on('data', c => {
    if (byteLength < MAX_STDIN) {
      const remaining = MAX_STDIN - byteLength;
      if (c.length > remaining) {
        chunks.push(c.subarray(0, remaining));
        byteLength += remaining;
        truncated = true;
      } else {
        chunks.push(c);
        byteLength += c.length;
      }
    } else {
      truncated = true;
    }
  });

  process.stdin.on('end', () => {
    const data = Buffer.concat(chunks).toString('utf8');
    const result = run(data);

    if (result.stderr) {
      process.stderr.write(`${result.stderr}\n`);
    }

    if (Object.prototype.hasOwnProperty.call(result, 'additionalContext')) {
      process.stdout.write(buildPreToolUseAdditionalContext(result.additionalContext));
    } else if (!truncated) {
      process.stdout.write(data);
    }
  });
}
