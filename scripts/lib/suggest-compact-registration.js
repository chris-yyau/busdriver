'use strict';

/**
 * Detect whether hooks.json PreToolUse actually invokes suggest-compact.js.
 * Used by harness-audit Context Efficiency scoring.
 */

/** Relative plugin path that must appear for Context Efficiency credit. */
const SUGGEST_COMPACT_SCRIPT = 'scripts/hooks/suggest-compact.js';

/**
 * Claude Code plugin/user hooks.json nest events under `hooks` (see
 * hooks/hooks.json `$schema`). Accept a top-level PreToolUse only as a
 * defensive fallback for atypical fixtures.
 */
function getPreToolUseEntries(config) {
  if (!config || typeof config !== 'object') {
    return [];
  }
  if (config.hooks && Array.isArray(config.hooks.PreToolUse)) {
    return config.hooks.PreToolUse;
  }
  if (Array.isArray(config.PreToolUse)) {
    return config.PreToolUse;
  }
  return [];
}

function isSuggestCompactScriptToken(value) {
  return typeof value === 'string' && value.includes(SUGGEST_COMPACT_SCRIPT);
}

function isNodeToken(value) {
  return typeof value === 'string' && /(?:^|\/)node(?:\.exe)?$/.test(value);
}

function isRunWithFlagsToken(value) {
  return typeof value === 'string' && value.includes('run-with-flags.js');
}

/** Strip leading FOO=bar assignments so the statement command word is visible. */
function stripLeadingEnvAssignments(statement) {
  return statement.replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|[^\s]+)\s+)*/, '');
}

/** First argv word (supports quoted absolute paths like "/usr/bin/node"). */
function commandWordAndRest(statement) {
  const match = statement.match(/^(?:"([^"]+)"|'([^']+)'|(\S+))([\s\S]*)$/);
  if (!match) {
    return null;
  }
  return {
    word: match[1] || match[2] || match[3],
    rest: (match[4] || '').trim(),
  };
}

function tokenizeShellArgs(rest) {
  const tokens = [];
  const re = /"([^"]*)"|'([^']*)'|(\S+)/g;
  let match = re.exec(rest);
  while (match !== null) {
    tokens.push(match[1] !== undefined ? match[1] : match[2] !== undefined ? match[2] : match[3]);
    match = re.exec(rest);
  }
  return tokens;
}

function precedingTokenIsNode(tokens, scriptIndex) {
  return scriptIndex > 0 && isNodeToken(tokens[scriptIndex - 1]);
}

/**
 * run-with-flags.js <hookId> <scriptRelativePath> [profilesCsv]
 * Only counts when node launches the wrapper and the script is in argv slot +2.
 */
function scriptIsRunWithFlagsScriptArg(tokens, scriptIndex) {
  for (let j = 0; j < scriptIndex; j += 1) {
    if (!isRunWithFlagsToken(tokens[j])) {
      continue;
    }
    if (j === 0 || !isNodeToken(tokens[j - 1])) {
      continue;
    }
    if (scriptIndex === j + 2) {
      return true;
    }
  }
  return false;
}

/**
 * Exec-form argv (`command` launcher + `args`): script must be a node argv or
 * the run-with-flags scriptRelativePath where node launched that wrapper.
 */
function execArgvInvokesSuggestCompact(tokens) {
  for (let i = 0; i < tokens.length; i += 1) {
    if (!isSuggestCompactScriptToken(tokens[i])) {
      continue;
    }
    if (precedingTokenIsNode(tokens, i)) {
      return true;
    }
    if (scriptIsRunWithFlagsScriptArg(tokens, i)) {
      return true;
    }
  }
  return false;
}

function shellStatementInvokesSuggestCompact(statement) {
  const trimmed = typeof statement === 'string' ? statement.trim() : '';
  if (!trimmed.includes(SUGGEST_COMPACT_SCRIPT)) {
    return false;
  }
  const withoutEnv = stripLeadingEnvAssignments(trimmed);
  const parts = commandWordAndRest(withoutEnv);
  if (!parts || !isNodeToken(parts.word)) {
    return false;
  }
  return execArgvInvokesSuggestCompact([parts.word, ...tokenizeShellArgs(parts.rest)]);
}

function shellCommandInvokesSuggestCompact(command) {
  if (typeof command !== 'string' || !command.includes(SUGGEST_COMPACT_SCRIPT)) {
    return false;
  }
  const statements = command.split(/[;|&\n]/);
  for (const statement of statements) {
    if (shellStatementInvokesSuggestCompact(statement)) {
      return true;
    }
  }
  return false;
}

function hookArgvTokens(hook) {
  const tokens = [];
  if (typeof hook.command === 'string' && hook.command.length > 0) {
    tokens.push(hook.command);
  }
  if (Array.isArray(hook.args)) {
    for (const arg of hook.args) {
      if (typeof arg === 'string') {
        tokens.push(arg);
      }
    }
  }
  return tokens;
}

/**
 * True when a PreToolUse hook actually invokes suggest-compact.js (direct node
 * or run-with-flags scriptRelativePath), including exec-form command+args.
 */
function hookRegistersSuggestCompact(hook) {
  if (!hook || typeof hook !== 'object') {
    return false;
  }
  if (shellCommandInvokesSuggestCompact(hook.command)) {
    return true;
  }
  return execArgvInvokesSuggestCompact(hookArgvTokens(hook));
}

function preToolUseRegistersSuggestCompact(entries) {
  for (const entry of entries) {
    const hooks = entry && Array.isArray(entry.hooks) ? entry.hooks : [];
    for (const hook of hooks) {
      if (hookRegistersSuggestCompact(hook)) {
        return true;
      }
    }
  }
  return false;
}

module.exports = {
  SUGGEST_COMPACT_SCRIPT,
  getPreToolUseEntries,
  preToolUseRegistersSuggestCompact,
  hookRegistersSuggestCompact,
};
