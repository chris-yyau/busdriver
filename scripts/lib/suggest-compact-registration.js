'use strict';

/**
 * Detect whether hooks.json PreToolUse actually invokes suggest-compact.js.
 * Used by harness-audit Context Efficiency scoring.
 */

/** Relative plugin path that must appear for Context Efficiency credit. */
const SUGGEST_COMPACT_SCRIPT = 'scripts/hooks/suggest-compact.js';

/** Path-bounded match; rejects suggest-compact.js.bak and similar suffixes. */
const SUGGEST_COMPACT_SCRIPT_IN_TEXT_RE =
  /(?:^|\/|["'])scripts\/hooks\/suggest-compact\.js(?:["']|$|[\s;|&])/;
const RUN_WITH_FLAGS_TOKEN_RE = /(?:^|\/)run-with-flags\.js$/;
/** Wrapper scriptRelativePath slot: exact relative path only. */
const SUGGEST_COMPACT_RELATIVE_RE = /^scripts\/hooks\/suggest-compact\.js$/;
/** Direct node argv: must be plugin-root qualified. */
const SUGGEST_COMPACT_PLUGIN_ROOT_RE =
  /^(?:\$\{CLAUDE_PLUGIN_ROOT\}|\$CLAUDE_PLUGIN_ROOT)\/scripts\/hooks\/suggest-compact\.js$/;

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

function stripWrappingQuotes(value) {
  return value.trim().replace(/^["']|["']$/g, '');
}

function isSuggestCompactRelativeToken(value) {
  return typeof value === 'string' && SUGGEST_COMPACT_RELATIVE_RE.test(stripWrappingQuotes(value));
}

function isSuggestCompactPluginRootToken(value) {
  return typeof value === 'string' && SUGGEST_COMPACT_PLUGIN_ROOT_RE.test(stripWrappingQuotes(value));
}

function textMentionsSuggestCompactScript(value) {
  return typeof value === 'string' && SUGGEST_COMPACT_SCRIPT_IN_TEXT_RE.test(value);
}

function isNodeToken(value) {
  return typeof value === 'string' && /(?:^|\/)node(?:\.exe)?$/.test(stripWrappingQuotes(value));
}

function isRunWithFlagsToken(value) {
  return typeof value === 'string' && RUN_WITH_FLAGS_TOKEN_RE.test(stripWrappingQuotes(value));
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

/** Direct form: command is node; argv[1] is ${CLAUDE_PLUGIN_ROOT}/…/suggest-compact.js. */
function isDirectNodeScriptInvocation(tokens, scriptIndex) {
  return scriptIndex === 1 && isNodeToken(tokens[0]) && isSuggestCompactPluginRootToken(tokens[1]);
}

/**
 * run-with-flags.js <hookId> <scriptRelativePath> [profilesCsv]
 * Requires node as argv[0], wrapper at [1], exact relative script at [3].
 */
function scriptIsRunWithFlagsScriptArg(tokens, scriptIndex) {
  if (scriptIndex !== 3) {
    return false;
  }
  return isNodeToken(tokens[0])
    && isRunWithFlagsToken(tokens[1])
    && isSuggestCompactRelativeToken(tokens[3]);
}

/**
 * Exec-form argv: command (tokens[0]) must be node. Rejects /bin/echo … node script.
 */
function execArgvInvokesSuggestCompact(tokens) {
  if (!isNodeToken(tokens[0])) {
    return false;
  }
  if (isDirectNodeScriptInvocation(tokens, 1)) {
    return true;
  }
  if (scriptIsRunWithFlagsScriptArg(tokens, 3)) {
    return true;
  }
  return false;
}

function shellStatementInvokesSuggestCompact(statement) {
  const trimmed = typeof statement === 'string' ? statement.trim() : '';
  if (!textMentionsSuggestCompactScript(trimmed)) {
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
  if (!textMentionsSuggestCompactScript(command)) {
    return false;
  }
  // Only the first `;`/`newline` statement is reachable for scoring — tails after
  // `exit 0; …` must not count. Keep `&&`/`||`/`|` intact inside that statement.
  const firstStatement = command.split(/[;\n]/)[0];
  return shellStatementInvokesSuggestCompact(firstStatement);
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
