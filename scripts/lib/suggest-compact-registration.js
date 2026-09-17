'use strict';

/**
 * Detect whether hooks.json PreToolUse actually invokes suggest-compact.js.
 * Used by harness-audit Context Efficiency scoring.
 */

/** Relative plugin path that must appear for Context Efficiency credit. */
const SUGGEST_COMPACT_SCRIPT = 'scripts/hooks/suggest-compact.js';

/** Path-bounded mention in shell text; rejects suggest-compact.js.bak. */
const SUGGEST_COMPACT_SCRIPT_IN_TEXT_RE =
  /(?:^|\/|["'])scripts\/hooks\/suggest-compact\.js(?:["']|$|[\s;|&])/;

/** Wrapper scriptRelativePath slot: exact relative path only. */
const SUGGEST_COMPACT_RELATIVE_RE = /^scripts\/hooks\/suggest-compact\.js$/;

/** Exec-form plugin-root paths: braced placeholder only (no shell expansion). */
const SUGGEST_COMPACT_PLUGIN_ROOT_BRACED_RE =
  /^\$\{CLAUDE_PLUGIN_ROOT\}\/scripts\/hooks\/suggest-compact\.js$/;
const RUN_WITH_FLAGS_PLUGIN_ROOT_BRACED_RE =
  /^\$\{CLAUDE_PLUGIN_ROOT\}\/scripts\/hooks\/run-with-flags\.js$/;

/** Shell-form may also use bare $CLAUDE_PLUGIN_ROOT (shell expands it). */
const SUGGEST_COMPACT_PLUGIN_ROOT_BARE_RE =
  /^\$CLAUDE_PLUGIN_ROOT\/scripts\/hooks\/suggest-compact\.js$/;
const RUN_WITH_FLAGS_PLUGIN_ROOT_BARE_RE =
  /^\$CLAUDE_PLUGIN_ROOT\/scripts\/hooks\/run-with-flags\.js$/;

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

function normalizeToken(value, stripQuotes) {
  if (typeof value !== 'string') {
    return '';
  }
  if (stripQuotes) {
    return stripWrappingQuotes(value);
  }
  return value.trim();
}

function isSuggestCompactRelativeToken(value, stripQuotes) {
  return SUGGEST_COMPACT_RELATIVE_RE.test(normalizeToken(value, stripQuotes));
}

function isSuggestCompactPluginRootToken(value, allowBare, stripQuotes) {
  const trimmed = normalizeToken(value, stripQuotes);
  if (SUGGEST_COMPACT_PLUGIN_ROOT_BRACED_RE.test(trimmed)) {
    return true;
  }
  if (!allowBare) {
    return false;
  }
  return SUGGEST_COMPACT_PLUGIN_ROOT_BARE_RE.test(trimmed);
}

function isRunWithFlagsToken(value, allowBare, stripQuotes) {
  const trimmed = normalizeToken(value, stripQuotes);
  if (RUN_WITH_FLAGS_PLUGIN_ROOT_BRACED_RE.test(trimmed)) {
    return true;
  }
  if (!allowBare) {
    return false;
  }
  return RUN_WITH_FLAGS_PLUGIN_ROOT_BARE_RE.test(trimmed);
}

function textMentionsSuggestCompactScript(value) {
  return typeof value === 'string' && SUGGEST_COMPACT_SCRIPT_IN_TEXT_RE.test(value);
}

function isNodeToken(value, stripQuotes) {
  return /(?:^|\/)node(?:\.exe)?$/.test(normalizeToken(value, stripQuotes));
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

/** Direct form: command is node; argv[1] is plugin-root suggest-compact.js. */
function isDirectNodeScriptInvocation(tokens, allowBare, stripQuotes) {
  return isNodeToken(tokens[0], stripQuotes)
    && isSuggestCompactPluginRootToken(tokens[1], allowBare, stripQuotes);
}

/**
 * run-with-flags.js <hookId> <scriptRelativePath> [profilesCsv]
 * Requires node as argv[0], plugin-root wrapper at [1], exact relative script at [3].
 */
function scriptIsRunWithFlagsScriptArg(tokens, allowBare, stripQuotes) {
  return isNodeToken(tokens[0], stripQuotes)
    && isRunWithFlagsToken(tokens[1], allowBare, stripQuotes)
    && isSuggestCompactRelativeToken(tokens[3], stripQuotes);
}

/**
 * Exec-form argv: command (tokens[0]) must be node. Rejects /bin/echo … node script.
 * @param {boolean} allowBarePluginRoot - true for shell-expanded command strings.
 * @param {boolean} stripQuotes - true after shell tokenization; false for raw exec argv.
 */
function execArgvInvokesSuggestCompact(tokens, allowBarePluginRoot, stripQuotes) {
  if (!isNodeToken(tokens[0], stripQuotes)) {
    return false;
  }
  if (isDirectNodeScriptInvocation(tokens, allowBarePluginRoot, stripQuotes)) {
    return true;
  }
  return scriptIsRunWithFlagsScriptArg(tokens, allowBarePluginRoot, stripQuotes);
}

function shellStatementInvokesSuggestCompact(statement) {
  const trimmed = typeof statement === 'string' ? statement.trim() : '';
  if (!textMentionsSuggestCompactScript(trimmed)) {
    return false;
  }
  const withoutEnv = stripLeadingEnvAssignments(trimmed);
  const parts = commandWordAndRest(withoutEnv);
  if (!parts || !isNodeToken(parts.word, true)) {
    return false;
  }
  return execArgvInvokesSuggestCompact(
    [parts.word, ...tokenizeShellArgs(parts.rest)],
    true,
    true
  );
}

function shellCommandInvokesSuggestCompact(command) {
  if (!textMentionsSuggestCompactScript(command)) {
    return false;
  }
  // Only the first `;`/`newline` statement is reachable for scoring.
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

function isSynchronousCommandHook(hook) {
  if (!hook || typeof hook !== 'object') {
    return false;
  }
  if (hook.type !== 'command') {
    return false;
  }
  if (hook.async === true) {
    return false;
  }
  return true;
}

function isEmptyMatcher(matcher) {
  if (matcher === undefined) {
    return true;
  }
  if (matcher === null) {
    return true;
  }
  return matcher === '';
}

/** Matcher must cover Edit/Write (documented surface), be empty (all tools), or `*`. */
function matcherCoversEditOrWrite(matcher) {
  if (isEmptyMatcher(matcher)) {
    return true;
  }
  if (typeof matcher !== 'string') {
    return false;
  }
  if (matcher === '*') {
    return true;
  }
  if (/\bEdit\b/.test(matcher)) {
    return true;
  }
  return /\bWrite\b/.test(matcher);
}

/**
 * True when a PreToolUse hook actually invokes suggest-compact.js (direct node
 * or run-with-flags scriptRelativePath), including exec-form command+args.
 * Only synchronous `type: "command"` hooks execute command/args usefully.
 */
function hookRegistersSuggestCompact(hook) {
  if (!isSynchronousCommandHook(hook)) {
    return false;
  }
  if (shellCommandInvokesSuggestCompact(hook.command)) {
    return true;
  }
  // Exec-form argv is not shell-parsed — do not strip literal quotes.
  return execArgvInvokesSuggestCompact(hookArgvTokens(hook), false, false);
}

function entryRegistersSuggestCompact(entry) {
  if (!matcherCoversEditOrWrite(entry && entry.matcher)) {
    return false;
  }
  const hooks = entry && Array.isArray(entry.hooks) ? entry.hooks : [];
  return hooks.some((hook) => hookRegistersSuggestCompact(hook));
}

function preToolUseRegistersSuggestCompact(entries) {
  return entries.some((entry) => entryRegistersSuggestCompact(entry));
}

module.exports = {
  SUGGEST_COMPACT_SCRIPT,
  getPreToolUseEntries,
  preToolUseRegistersSuggestCompact,
  hookRegistersSuggestCompact,
};
