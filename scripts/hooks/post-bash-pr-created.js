#!/usr/bin/env node
/**
 * PostToolUse hook: after `gh pr create` succeeds, instruct Claude
 * to invoke pr-grind and clear any stale pr-grind-clean marker.
 *
 * Output protocol:
 *   - Returns modified JSON with instruction appended to tool_output
 *   - Writes the PR URL to .claude/pr-pending-grind.local
 *   - Removes stale .claude/pr-grind-clean.local (new PR invalidates old marker)
 */

'use strict';

const fs = require('fs');
const path = require('path');

/**
 * Core logic — called by run-with-flags.js via direct require().
 *
 * @param {string} rawInput - Raw JSON from stdin (PostToolUse hook data)
 * @returns {string|object} Modified output or pass-through
 */
function run(rawInput) {
  try {
    const input = JSON.parse(rawInput);
    const cmd = String(input.tool_input?.command || '');

    if (!/\bgh\s+pr\s+create\b/.test(cmd)) {
      return rawInput;
    }

    const out = String(input.tool_output?.output || '');
    const match = out.match(/https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/\d+/);

    if (!match) {
      return rawInput;
    }

    const prUrl = match[0];
    const prNum = prUrl.replace(/.+\/pull\/(\d+)/, '$1');

    // Write pending-grind marker so we know which PR needs grinding
    try {
      const stateDir = process.env.BUSDRIVER_STATE_DIR || '.claude';
      const stateDirPath = path.resolve(stateDir);
      if (fs.existsSync(stateDirPath)) {
        fs.writeFileSync(
          path.join(stateDirPath, 'pr-pending-grind.local'),
          `${prUrl}\n`,
          'utf8'
        );
        // Invalidate any stale pr-grind-clean marker from a previous PR
        const cleanMarker = path.join(stateDirPath, 'pr-grind-clean.local');
        if (fs.existsSync(cleanMarker)) {
          fs.unlinkSync(cleanMarker);
        }
      }
    } catch {
      // Non-fatal — marker write failure shouldn't break the hook
    }

    // Append instruction to tool output so Claude sees it
    const instruction = [
      '',
      '─── PR Grind Required ───',
      `PR #${prNum} created: ${prUrl}`,
      '',
      'You MUST now invoke `busdriver:pr-grind` (or `/pr-grind`).',
      'It will grind reviewer feedback and merge when clean (default behavior).',
      'Do NOT run `gh pr merge` separately — pr-grind owns the merge.',
      '',
      'Do NOT enable GitHub auto-merge or give compound "grind then merge" instructions.',
      'Use `busdriver:pr-grind --no-merge` if you want to stop at "Ready for merge".',
      '─────────────────────────'
    ].join('\n');

    const modifiedOutput = out + instruction;

    // Return modified JSON with the instruction appended
    const modified = { ...input };
    if (!modified.tool_output) {
      modified.tool_output = {};
    }
    modified.tool_output = { ...modified.tool_output, output: modifiedOutput };

    return {
      stdout: JSON.stringify(modified),
      stderr: `[Hook] PR #${prNum} created — pr-grind required before merge\n`
    };
  } catch {
    return rawInput;
  }
}

// ── stdin entry point (backwards-compatible) ────────────────────
if (require.main === module) {
  const MAX_STDIN = 1024 * 1024;
  let raw = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => {
    if (raw.length < MAX_STDIN) {
      const remaining = MAX_STDIN - raw.length;
      raw += chunk.substring(0, remaining);
    }
  });

  process.stdin.on('end', () => {
    const result = run(raw);
    if (typeof result === 'string') {
      process.stdout.write(result);
    } else if (result && typeof result === 'object') {
      if (result.stderr) {
        process.stderr.write(result.stderr);
      }
      process.stdout.write(result.stdout || raw);
    }
  });
}

module.exports = { run };
