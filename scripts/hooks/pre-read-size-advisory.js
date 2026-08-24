#!/usr/bin/env node
/**
 * Read size advisory (PreToolUse - Read)
 *
 * Fail-open advisory: when a wholesale Read targets a file over ~200 lines,
 * surface that it exceeds the self-read threshold and narrowing-first
 * guidance. Silent when limit/offset is set, under threshold, outside the
 * workspace root, or on any error. Never blocks, never reads file content
 * into context.
 *
 * Intentional residual (issue #626, Council Option A): this decision-time
 * advisory intentionally performs a BOUNDED probe (open + scan, <= 1 MiB,
 * realpath-contained to the payload cwd) BEFORE the Read permission decision,
 * disclosing only a coarse existence/regularity/over-threshold predicate about
 * the model-named path. Do NOT deploy where pre-permission probing is
 * unacceptable; hook privilege MUST remain <= model privilege.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { buildPreToolUseAdditionalContext } = require('./pretooluse-visible-output');
const { assertWithinTrustedRoot } = require('../lib/path-safety.js');

const MAX_STDIN = 1024 * 1024;
const THRESHOLD = 200;
const READ_CHUNK = 64 * 1024;
const MAX_SCAN_BYTES = 50 * 1024 * 1024;
const MAX_WORK_BYTES = 1024 * 1024;
const OPEN_FLAGS = fs.constants.O_RDONLY | (fs.constants.O_NONBLOCK || 0);
let data = '';

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
// NUL is still detected before any over-threshold classification.
function scanWindow(fd, size, end, buffer) {
  let lines = 0;
  let lastByte = 0;
  let offset = 0;
  while (offset < end) {
    const toRead = Math.min(READ_CHUNK, size - offset);
    const read = fs.readSync(fd, buffer, 0, toRead, offset);
    if (read <= 0) break;
    if (buffer.subarray(0, read).includes(0)) return null;
    for (let i = 0; i < read; i++) {
      if (buffer[i] === 0x0a) lines++;
      lastByte = buffer[i];
    }
    offset += read;
  }
  return { lines, lastByte, offset };
}

function countLines(filePath) {
  let fd;
  try {
    fd = fs.openSync(filePath, OPEN_FLAGS);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) return null;
    // TOCTOU closure: the path may have been swapped for a symlink between the
    // containment check and this open. The held fd must be the same file the
    // contained path resolves to NOW, or stay silent.
    const pathStat = fs.statSync(filePath);
    if (pathStat.dev !== stat.dev || pathStat.ino !== stat.ino) return null;
    if (stat.size === 0) return 0;
    if (stat.size > MAX_SCAN_BYTES) return null;

    const buffer = Buffer.alloc(READ_CHUNK);
    // Fixed work budget independent of newline count: at most MAX_WORK_BYTES
    // scanned (the bounded probe). Budget exhausted with the count still
    // unknown → silent; the advisory only fires on a VERIFIED over-threshold.
    const window = scanWindow(fd, stat.size, Math.min(stat.size, MAX_WORK_BYTES), buffer);
    if (window === null) return null;

    if (window.lines > THRESHOLD) return window.lines;
    if (window.offset < stat.size) return null;
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

  const resolved = resolveContained(filePath, input?.cwd || process.cwd());
  if (resolved === null) {
    return { exitCode: 0 };
  }

  const lines = countLines(resolved);
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
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', c => {
    if (data.length < MAX_STDIN) {
      const remaining = MAX_STDIN - data.length;
      data += c.substring(0, remaining);
    }
  });

  process.stdin.on('end', () => {
    const result = run(data);

    if (result.stderr) {
      process.stderr.write(`${result.stderr}\n`);
    }

    if (Object.prototype.hasOwnProperty.call(result, 'additionalContext')) {
      process.stdout.write(buildPreToolUseAdditionalContext(result.additionalContext));
    } else {
      process.stdout.write(data);
    }
  });
}
