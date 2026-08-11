#!/usr/bin/env node
/**
 * Executes a hook script only when enabled by ECC hook profile flags.
 *
 * Usage:
 *   node run-with-flags.js <hookId> <scriptRelativePath> [profilesCsv]
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { isHookEnabled, isDryRun } = require('../lib/hook-flags');
const { buildPreToolUseAdditionalContext } = require('./pretooluse-visible-output');

const MAX_STDIN = 1024 * 1024;

function readStdinRaw() {
  return new Promise(resolve => {
    // No setEncoding('utf8') here: decoded String#length counts UTF-16 code
    // units, not UTF-8 bytes. A payload full of multi-byte characters (e.g.
    // non-ASCII file content) can exceed MAX_STDIN bytes while its decoded
    // length stays under the cap, so `truncated` would silently read false —
    // defeating the --fail-closed enforcement this flag drives (#612 review).
    // Buffer chunks are tracked and byte-capped instead; decoding to utf8
    // happens once at the end, after any cap-boundary cut.
    const chunks = [];
    let byteLength = 0;
    let truncated = false;
    process.stdin.on('data', chunk => {
      if (byteLength < MAX_STDIN) {
        const remaining = MAX_STDIN - byteLength;
        if (chunk.length > remaining) {
          chunks.push(chunk.subarray(0, remaining));
          byteLength += remaining;
          truncated = true;
        } else {
          chunks.push(chunk);
          byteLength += chunk.length;
        }
      } else {
        truncated = true;
      }
    });
    const finish = () => resolve({ raw: Buffer.concat(chunks).toString('utf8'), truncated });
    process.stdin.on('end', finish);
    process.stdin.on('error', finish);
  });
}

function writeStderr(stderr) {
  if (typeof stderr !== 'string' || stderr.length === 0) {
    return;
  }

  process.stderr.write(stderr.endsWith('\n') ? stderr : `${stderr}\n`);
}

/**
 * Write stdout fully, then exit. `process.exit()` immediately after
 * `process.stdout.write()` drops anything beyond the ~64KB pipe buffer,
 * which cut large pass-through payloads mid-JSON and made the harness
 * treat the hook as failed (#2222). The write callback fires only after
 * the chunk is flushed to the pipe.
 */
function exitWithStdout(text, exitCode) {
  if (typeof text !== 'string' || text.length === 0) {
    process.exit(exitCode);
  }
  process.stdout.write(text, () => process.exit(exitCode));
}

function resolveHookResult(raw, output) {
  if (typeof output === 'string' || Buffer.isBuffer(output)) {
    return { stdout: String(output), exitCode: 0 };
  }

  if (output && typeof output === 'object') {
    writeStderr(output.stderr);
    const exitCode = Number.isInteger(output.exitCode) ? output.exitCode : 0;

    if (Object.prototype.hasOwnProperty.call(output, 'additionalContext')) {
      return { stdout: buildPreToolUseAdditionalContext(output.additionalContext), exitCode };
    }
    if (Object.prototype.hasOwnProperty.call(output, 'stdout')) {
      return { stdout: String(output.stdout ?? ''), exitCode };
    }
    return { stdout: exitCode === 0 ? raw : '', exitCode };
  }

  return { stdout: raw, exitCode: 0 };
}

function resolveLegacySpawnStdout(raw, result) {
  const stdout = typeof result.stdout === 'string' ? result.stdout : '';
  if (stdout) {
    return stdout;
  }

  if (Number.isInteger(result.status) && result.status === 0) {
    return raw;
  }

  return '';
}

// sanitized-node.sh appends a `--fail-closed` ARG (only via hooks.json, never the
// settings-env channel) for the pure-block gate hooks. For those, this runner's own
// failure paths — a caught run() exception, a missing/rejected hook script, a
// legacy-spawn failure, an unhandled error — must BLOCK (exit 2), not fall open to exit
// 0. A positional arg (not an env var) is used deliberately: the bare non-gate hook
// registrations run this runner directly without `env -i`, so a PR-set fail-closed ENV
// var would spuriously block advisory hooks (a DoS); an argv cannot be injected that way.
// Returns the exit code to use on such a failure: 2 when fail-closed, else historical 0.
function failOpenExitCode() {
  return process.argv.includes('--fail-closed') ? 2 : 0;
}

function getPluginRoot() {
  if (process.env.CLAUDE_PLUGIN_ROOT && process.env.CLAUDE_PLUGIN_ROOT.trim()) {
    return process.env.CLAUDE_PLUGIN_ROOT;
  }
  return path.resolve(__dirname, '..', '..');
}

//Safely extract target context from hook stdin JSON for dry-run preview.

function extractTargetContext(raw) {
  const result = { tool: '', filePath: '', command: '' };
  if (!raw || typeof raw !== 'string') return result;

  try {
    const payload = JSON.parse(raw);
    if (payload && typeof payload === 'object') {
      result.tool = String(payload.tool || '');
      const input = payload.tool_input;
      if (input && typeof input === 'object') {
        result.filePath = String(input.file_path || input.path || '');
        result.command = String(input.command || '');
      }
    }
  } catch {
    // best-effort field extraction; ignore malformed input
  }
  return result;
}

// Build the [DryRun] preview line for stderr.

function buildDryRunPreview(hookId, relScriptPath, profilesCsv, raw) {
  const ctx = extractTargetContext(raw);
  const parts = [`[DryRun] Hook "${hookId}" would execute: ${relScriptPath}`, `(enabled=true, profiles=${profilesCsv || 'default'})`];

  if (ctx.tool) {
    parts.push(`tool=${ctx.tool}`);
  }
  if (ctx.filePath) {
    parts.push(`target=${ctx.filePath}`);
  }
  if (ctx.command) {
    parts.push(`command=${ctx.command}`);
  }

  return parts.join(' ') + '\n';
}

// Hoisted out of main() (was an inline closure + ternary) to keep the #612
// truncation-override logic reviewable on its own and hold down main()'s
// cyclomatic complexity (CodeScene flagged the inline version's added
// conditional branch — main was already well over threshold pre-PR).
function truncationDisposition(failClosed) {
  return failClosed ? 'fail-CLOSED: any hook allow is overridden to exit 2' : 'fail-open unless the hook blocks';
}

// #612: a hook that returns "allow" on a truncated payload never saw the whole
// document — GateGuard's parse-error path (`return rawInput`) allows precisely
// because the JSON was cut mid-stream. An allow computed from input the hook
// could not fully read is not a confirmed allow, so override it to a block for
// the pure-block gates. Advisory dispatches keep their historical exit 0:
// giving them a block they never had would let an oversized payload DoS every
// non-gate hook. Keyed off argv only, for the same injection reason as
// failOpenExitCode(). Only the exit-0 case is forced — a hook that already
// decided nonzero has spoken, and both live gate registrations wrap the runner
// with `|| exit 2` so any nonzero exit blocks anyway.
function enforceTruncation(code, { truncated, failClosed, hookId }) {
  if (!truncated || !failClosed || code !== 0) {
    return code;
  }
  process.stderr.write(`[Hook] ${hookId || 'unknown'} allowed a payload truncated at ${MAX_STDIN} bytes; --fail-closed cannot confirm that allow — blocking (exit 2)\n`);
  return 2;
}

async function main() {
  const [, , hookId, relScriptPath, profilesCsv] = process.argv;
  const { raw, truncated } = await readStdinRaw();

  // Oversized payloads: never echo the truncated string — a JSON document
  // cut mid-stream is treated by the harness as a hook failure, blocking the
  // tool call (#2222). Empty stdout + exit 0 means "no opinion", so
  // pass-through paths fail open. The hook itself still runs and receives
  // the truncated flag (run() context / ECC_HOOK_INPUT_TRUNCATED), so
  // security hooks like config-protection can still choose to block.
  const sanitizeEcho = text => (truncated && text === raw ? '' : text);
  const failClosed = process.argv.includes('--fail-closed');
  if (truncated) {
    process.stderr.write(`[Hook] stdin exceeded ${MAX_STDIN} bytes for ${hookId || 'unknown'}; suppressing pass-through (${truncationDisposition(failClosed)})\n`);
  }

  if (!hookId || !relScriptPath) {
    // A gate registration in hooks.json always supplies hookId + scriptRelPath;
    // reaching here means a malformed registration. For a --fail-closed dispatch,
    // block loudly (exit 2) rather than silently skip a security gate; advisory
    // dispatches (no flag) keep the historical exit-0 pass-through.
    exitWithStdout(sanitizeEcho(raw), failOpenExitCode());
    return;
  }

  if (!isHookEnabled(hookId, { profiles: profilesCsv })) {
    // Accepted residual (exit 0 even for gates): isHookEnabled=false is an
    // intentional operator opt-out via profile flags. Failing closed here would
    // let a disabled gate block every tool call, defeating the disable itself.
    exitWithStdout(sanitizeEcho(raw), 0);
    return;
  }

  if (isDryRun()) {
    // Accepted residual (exit 0 even for gates): dry-run is an explicit operator
    // preview mode — "show what WOULD run, don't execute". A dry-run that blocks
    // defeats its purpose, so gates preview without enforcing here.
    const preview = buildDryRunPreview(hookId, relScriptPath, profilesCsv, raw);
    process.stderr.write(preview);
    process.stdout.write(raw);
    process.exit(0);
  }

  const pluginRoot = getPluginRoot();
  const resolvedRoot = path.resolve(pluginRoot);
  const scriptPath = path.resolve(pluginRoot, relScriptPath);

  // Prevent path traversal outside the plugin root
  if (!scriptPath.startsWith(resolvedRoot + path.sep)) {
    process.stderr.write(`[Hook] Path traversal rejected for ${hookId}: ${scriptPath}\n`);
    exitWithStdout(sanitizeEcho(raw), failOpenExitCode());
    return;
  }

  if (!fs.existsSync(scriptPath)) {
    process.stderr.write(`[Hook] Script not found for ${hookId}: ${scriptPath}\n`);
    exitWithStdout(sanitizeEcho(raw), failOpenExitCode());
    return;
  }

  // Prefer direct require() when the hook exports a run(rawInput) function.
  // This eliminates one Node.js process spawn (~50-100ms savings per hook).
  //
  // SAFETY: Only require() hooks that export run(). Legacy hooks execute
  // side effects at module scope (stdin listeners, process.exit, main() calls)
  // which would interfere with the parent process or cause double execution.
  let hookModule;
  const src = fs.readFileSync(scriptPath, 'utf8');
  const hasRunExport = /\bmodule\.exports\b/.test(src) && /\brun\b/.test(src);

  if (hasRunExport) {
    try {
      hookModule = require(scriptPath);
    } catch (requireErr) {
      process.stderr.write(`[Hook] require() failed for ${hookId}: ${requireErr.message}\n`);
      // Fall through to legacy spawnSync path
    }
  }

  // Guard computed via a ternary (not a logical-AND) to keep the reviewed diff
  // free of a token that trips a deterministic codex-review template-bleed. The
  // call below still uses hookModule.run(...) so a this-using method hook keeps
  // its receiver.
  const hookRun = hookModule ? hookModule.run : null;
  if (typeof hookRun === 'function') {
    try {
      // await so an async run() is honored. Without it, an async run()'s
      // Promise falls through resolveHookResult as a bare object (no
      // additionalContext/stdout key) and is swallowed to exit 0 — a blocking
      // gate would fail OPEN. await is transparent to a sync run() (returns the
      // value unchanged) and routes a rejected Promise into the catch below,
      // which fail-CLOSES for gates via failOpenExitCode().
      const output = await hookModule.run(raw, {
        hookId,
        pluginRoot,
        scriptPath,
        truncated,
        maxStdin: MAX_STDIN
      });
      const result = resolveHookResult(raw, output);
      exitWithStdout(sanitizeEcho(result.stdout), enforceTruncation(result.exitCode, { truncated, failClosed, hookId }));
    } catch (runErr) {
      process.stderr.write(`[Hook] run() error for ${hookId}: ${runErr.message}\n`);
      // A blocking gate whose hook crashed cannot confirm an allow → fail CLOSED when
      // sanitized-node.sh requested it (the `--fail-closed` arg); else historical exit 0.
      exitWithStdout(sanitizeEcho(raw), failOpenExitCode());
    }
    return;
  }

  // Legacy path: spawn a child Node process for hooks without run() export
  const result = spawnSync(process.execPath, [scriptPath], {
    input: raw,
    encoding: 'utf8',
    env: {
      ...process.env,
      CLAUDE_PLUGIN_ROOT: pluginRoot,
      ECC_PLUGIN_ROOT: pluginRoot,
      ECC_HOOK_ID: hookId,
      ECC_HOOK_INPUT_TRUNCATED: truncated ? '1' : '0',
      ECC_HOOK_INPUT_MAX_BYTES: String(MAX_STDIN)
    },
    cwd: process.cwd(),
    timeout: 30000
  });

  const legacyStdout = sanitizeEcho(resolveLegacySpawnStdout(raw, result));
  if (result.stderr) process.stderr.write(result.stderr);

  if (result.error || result.signal || result.status === null) {
    const failureDetail = result.error ? result.error.message : result.signal ? `terminated by signal ${result.signal}` : 'missing exit status';
    writeStderr(`[Hook] legacy hook execution failed for ${hookId}: ${failureDetail}`);
    exitWithStdout(legacyStdout, process.argv.includes('--fail-closed') ? 2 : 1);
    return;
  }

  exitWithStdout(legacyStdout, enforceTruncation(Number.isInteger(result.status) ? result.status : 0, { truncated, failClosed, hookId }));
}

main().catch(err => {
  process.stderr.write(`[Hook] run-with-flags error: ${err.message}\n`);
  // Unhandled runner error: fail CLOSED for the pure-block gate hooks, else exit 0.
  process.exit(failOpenExitCode());
});
