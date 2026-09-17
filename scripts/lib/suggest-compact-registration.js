'use strict';

/**
 * Detect whether hooks.json PreToolUse actually invokes suggest-compact.js.
 * Used by harness-audit Context Efficiency scoring.
 */

const path = require('path');

/** Relative plugin path that must appear for Context Efficiency credit. */
const SUGGEST_COMPACT_SCRIPT = 'scripts/hooks/suggest-compact.js';
const RUN_WITH_FLAGS_SCRIPT = 'scripts/hooks/run-with-flags.js';

/** Path-bounded mention in shell text; rejects suggest-compact.js.bak. */
const SUGGEST_COMPACT_SCRIPT_IN_TEXT_RE =
  /(?:^|\/|["'])scripts\/hooks\/suggest-compact\.js(?:["']|$|[\s;|&])/;

/** Wrapper scriptRelativePath slot: exact relative path only. */
const SUGGEST_COMPACT_RELATIVE_RE = /^scripts\/hooks\/suggest-compact\.js$/;

/** Source-tree placeholders (before installer substitution). */
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

/** Absolute path equal to rootDir/scriptRelative (installer-resolved hooks.json). */
function isAuditedRootScriptPath(token, rootDir, scriptRelative) {
  if (!rootDir) {
    return false;
  }
  if (typeof token !== 'string') {
    return false;
  }
  if (!path.isAbsolute(token)) {
    return false;
  }
  return path.resolve(token) === path.resolve(rootDir, scriptRelative);
}

function isSuggestCompactRelativeToken(value, stripQuotes) {
  return SUGGEST_COMPACT_RELATIVE_RE.test(normalizeToken(value, stripQuotes));
}

function isSuggestCompactPluginRootToken(value, allowBare, stripQuotes, rootDir) {
  const trimmed = normalizeToken(value, stripQuotes);
  if (SUGGEST_COMPACT_PLUGIN_ROOT_BRACED_RE.test(trimmed)) {
    return true;
  }
  if (isAuditedRootScriptPath(trimmed, rootDir, SUGGEST_COMPACT_SCRIPT)) {
    return true;
  }
  if (!allowBare) {
    return false;
  }
  return SUGGEST_COMPACT_PLUGIN_ROOT_BARE_RE.test(trimmed);
}

function isRunWithFlagsToken(value, allowBare, stripQuotes, rootDir) {
  const trimmed = normalizeToken(value, stripQuotes);
  if (RUN_WITH_FLAGS_PLUGIN_ROOT_BRACED_RE.test(trimmed)) {
    return true;
  }
  if (isAuditedRootScriptPath(trimmed, rootDir, RUN_WITH_FLAGS_SCRIPT)) {
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
  const trimmed = normalizeToken(value, stripQuotes);
  if (/(?:^|\/)node(?:\.exe)?$/.test(trimmed)) {
    return true;
  }
  // Windows absolute launchers: C:\...\node.exe
  return /(?:^|[\\/])node(?:\.exe)?$/i.test(trimmed);
}

/** Any stdout redirect or pipe hides additionalContext (stderr-only 2> is fine). */
function discardsStdout(statement) {
  // Pipe only — not logical OR (||). Cubic: `|| exit 1` must still score.
  if (/(^|[^|])\|([^|]|$)/.test(statement)) {
    return true;
  }
  if (/&>/.test(statement)) {
    return true;
  }
  if (/\b1>>?\s*\S+/.test(statement)) {
    return true;
  }
  return /(?:^|[^0-9&])>>?\s*\S+/.test(statement);
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

function isDirectNodeScriptInvocation(tokens, allowBare, stripQuotes, rootDir) {
  return isNodeToken(tokens[0], stripQuotes)
    && isSuggestCompactPluginRootToken(tokens[1], allowBare, stripQuotes, rootDir);
}

function scriptIsRunWithFlagsScriptArg(tokens, allowBare, stripQuotes, rootDir) {
  const hookId = tokens[2];
  if (typeof hookId !== 'string' || hookId.length === 0) {
    return false;
  }
  return isNodeToken(tokens[0], stripQuotes)
    && isRunWithFlagsToken(tokens[1], allowBare, stripQuotes, rootDir)
    && isSuggestCompactRelativeToken(tokens[3], stripQuotes);
}

function execArgvInvokesSuggestCompact(tokens, allowBarePluginRoot, stripQuotes, rootDir) {
  if (!isNodeToken(tokens[0], stripQuotes)) {
    return false;
  }
  if (isDirectNodeScriptInvocation(tokens, allowBarePluginRoot, stripQuotes, rootDir)) {
    return true;
  }
  return scriptIsRunWithFlagsScriptArg(tokens, allowBarePluginRoot, stripQuotes, rootDir);
}

function shellStatementInvokesSuggestCompact(statement, rootDir) {
  const trimmed = typeof statement === 'string' ? statement.trim() : '';
  if (!textMentionsSuggestCompactScript(trimmed)) {
    return false;
  }
  if (discardsStdout(trimmed)) {
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
    true,
    rootDir
  );
}

function shellCommandInvokesSuggestCompact(command, rootDir) {
  if (!textMentionsSuggestCompactScript(command)) {
    return false;
  }
  const firstStatement = command.split(/[;\n]/)[0];
  return shellStatementInvokesSuggestCompact(firstStatement, rootDir);
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
  try {
    const re = new RegExp(matcher);
    if (re.test('Edit')) {
      return true;
    }
    return re.test('Write');
  } catch (_error) {
    return false;
  }
}

function hookRegistersSuggestCompact(hook, rootDir) {
  if (!isSynchronousCommandHook(hook)) {
    return false;
  }
  if (shellCommandInvokesSuggestCompact(hook.command, rootDir)) {
    return true;
  }
  return execArgvInvokesSuggestCompact(hookArgvTokens(hook), false, false, rootDir);
}

function entryRegistersSuggestCompact(entry, rootDir) {
  if (!matcherCoversEditOrWrite(entry && entry.matcher)) {
    return false;
  }
  const hooks = entry && Array.isArray(entry.hooks) ? entry.hooks : [];
  return hooks.some((hook) => hookRegistersSuggestCompact(hook, rootDir));
}

function preToolUseRegistersSuggestCompact(entries, rootDir) {
  return entries.some((entry) => entryRegistersSuggestCompact(entry, rootDir));
}

module.exports = {
  SUGGEST_COMPACT_SCRIPT,
  getPreToolUseEntries,
  preToolUseRegistersSuggestCompact,
  hookRegistersSuggestCompact,
};
