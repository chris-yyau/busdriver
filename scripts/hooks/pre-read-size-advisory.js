#!/usr/bin/env node
/**
 * Read size advisory (PreToolUse - Read)
 *
 * Fail-open advisory: when a wholesale Read targets a file over ~200 lines,
 * surface the line count and narrowing-first guidance. Silent when limit is
 * already set, under threshold, or on any error. Never blocks, never reads
 * file content into context.
 */

'use strict';

const fs = require('fs');
const { buildPreToolUseAdditionalContext } = require('./pretooluse-visible-output');

const MAX_STDIN = 1024 * 1024;
const THRESHOLD = 200;
const READ_CHUNK = 64 * 1024;
const MAX_SCAN_BYTES = 50 * 1024 * 1024;
const OPEN_FLAGS = fs.constants.O_RDONLY | (fs.constants.O_NONBLOCK || 0);
let data = '';

function isSafePath(filePath) {
  const value = String(filePath);
  return value.length > 0 && !/[\x00-\x1f\x7f\u0085\u2028\u2029]/.test(value);
}

function countLines(filePath) {
  let fd;
  try {
    fd = fs.openSync(filePath, OPEN_FLAGS);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) return null;
    if (stat.size === 0) return 0;
    if (stat.size > MAX_SCAN_BYTES) return null;

    const buffer = Buffer.alloc(READ_CHUNK);
    let lines = 0;
    let lastByte = 0;
    let offset = 0;

    while (offset < stat.size) {
      const toRead = Math.min(READ_CHUNK, stat.size - offset);
      const read = fs.readSync(fd, buffer, 0, toRead, offset);
      if (read <= 0) break;

      for (let i = 0; i < read; i++) {
        if (buffer[i] === 0x0a) lines++;
        lastByte = buffer[i];
      }
      offset += read;
    }

    if (lastByte !== 0x0a) lines++;
    return lines;
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

  const { file_path: filePath, limit } = input?.tool_input || {};
  if (limit || !filePath || !isSafePath(filePath)) {
    return { exitCode: 0 };
  }

  const lines = countLines(String(filePath));
  if (lines === null || lines <= THRESHOLD) {
    return { exitCode: 0 };
  }

  return {
    exitCode: 0,
    additionalContext: [
      `[Hook] ${filePath} is ${lines} lines - over the ~200-line self-read threshold.`,
      '[Hook] 1) Do you need all of it? Narrow with offset/limit - free, no dispatch floor.',
      '[Hook] 2) Otherwise route to pi. Both trust gates are yours to judge, not this hook\'s.',
    ],
  };
}

module.exports = { run, countLines, isSafePath, THRESHOLD };

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
