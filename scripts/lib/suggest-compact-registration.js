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
  /(?:^|[\s\/"'])scripts\/hooks\/suggest-compact\.js(?:["']|$|[\s;|&])/;

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
  // nosemgrep: javascript.lang.security.audit.path-traversal.path-join-resolve-traversal.path-join-resolve-traversal -- equality check against the audited root; nothing is read
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
  // `>` excluded so the second `>` of a stderr `2>>` is not read as stdout.
  return /(?:^|[^0-9&>])>>?\s*\S+/.test(statement);
}

/**
 * Split a whole shell statement into argv, consuming every character; any
 * unsupported syntax returns null (no credit). Accepted: whitespace,
 * `<` / `0<` / `2>` / `2>>` with `/dev/null`, and words that are wholly
 * double-quoted, wholly single-quoted, or plain. Word boundaries are enforced,
 * so `"x".bak` and `"node""x"` never split into separate args.
 */
function tokenizeShellArgs(rest) {
  const tokens = [];
  // ponytail: conservative shell subset; extend only with regression cases.
  // No `2>&1`: the hook logs to stderr before its JSON, so merging corrupts stdout.
  const re = /[ \t]+|(?:(0?<|2>>?)[ \t]*)?("[^"]*"|'[^']*'|[^\s"'<>|;&()\\$`#*?[\]{}~]+)(?=[ \t<>]|$)/y;

  while (re.lastIndex < rest.length) {
    const match = re.exec(rest);
    if (!match) {
      return null;
    }
    if (match[2] === undefined) {
      continue;
    }

    const raw = match[2];
    const quoted = raw[0] === '"' || raw[0] === "'";
    const word = quoted ? raw.slice(1, -1) : raw;

    // An unsupported IO number must not become an ordinary argv word.
    if (!quoted && /^\d+$/.test(raw) && /[<>]/.test(rest[re.lastIndex] || '')) {
      return null;
    }
    if (word !== word.trim()) {
      return null;
    }
    // Only a double-quoted plugin-root placeholder may expand; `'${...}'` is literal.
    if (word.includes('$') && (raw[0] !== '"'
      || !/^\$(?:\{CLAUDE_PLUGIN_ROOT\}|CLAUDE_PLUGIN_ROOT)\/scripts\/hooks\/(?:suggest-compact|run-with-flags)\.js$/.test(word))) {
      return null;
    }

    if (match[1]) {
      if (word !== '/dev/null') {
        return null;
      }
    } else {
      tokens.push(word);
    }
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

/**
 * Subshells, command and process substitution (`(`, `$(`, `<(`, backticks)
 * and escaping backslashes make argv unknowable statically: no credit rather
 * than a guess. Quoted literal parentheses (`"/tmp/plugin (copy)/..."`) are
 * plain text; `$(` and backticks still expand inside double quotes. Inside
 * double quotes a backslash is literal unless it precedes $ ` " \ or newline.
 */
function hasUnparseableShellSyntax(statement) {
  let quote = '';
  for (let i = 0; i < statement.length; i += 1) {
    const c = statement[i];
    if (quote === "'") {
      if (c === "'") {
        quote = '';
      }
      continue;
    }
    if (c === '\\') {
      if (quote !== '"' || /[$`"\\\n]/.test(statement[i + 1] || '')) {
        return true;
      }
      continue;
    }
    if (c === '`' || (c === '$' && statement[i + 1] === '(')) {
      return true;
    }
    if (quote === '"') {
      if (c === '"') {
        quote = '';
      }
      continue;
    }
    if (c === '"' || c === "'") {
      quote = c;
      continue;
    }
    if (c === '(' || c === ')') {
      return true;
    }
  }
  // An unterminated quote is a shell syntax error: the hook never runs.
  return quote !== '';
}

/** `/a/missing/../x` normalizes lexically but need not resolve on disk. */
function isNonNormalAbsolutePath(token) {
  return typeof token === 'string' && path.isAbsolute(token)
    && token !== path.normalize(token);
}

function shellStatementInvokesSuggestCompact(statement, rootDir) {
  const trimmed = typeof statement === 'string' ? statement.trim() : '';
  if (!textMentionsSuggestCompactScript(trimmed)) {
    return false;
  }
  if (discardsStdout(trimmed)) {
    return false;
  }
  if (hasUnparseableShellSyntax(trimmed)) {
    return false;
  }
  const tokens = tokenizeShellArgs(trimmed);
  if (!tokens) {
    return false;
  }
  if (isNonNormalAbsolutePath(tokens[1])) {
    return false;
  }
  return execArgvInvokesSuggestCompact(tokens, true, false, rootDir);
}

/** Match one trailing silent handler: `|| exit 1`, `&& true`, or `; :`. */
const SILENT_TRAILER_RE =
  /^(.*?)(?:\s*(?:\|\||&&|;)\s*)(exit\s+\d+|true|:)\s*$/;

/** Peel one silent trailer; return null if the peel emptied the command. */
function peelOneSilentTrailer(command) {
  const match = command.match(SILENT_TRAILER_RE);
  if (!match) {
    return command;
  }
  const head = match[1].trim();
  if (!head) {
    return null;
  }
  return head;
}

/** Keep peeling silent trailers until none remain (or the command empties). */
function peelSilentTrailers(command) {
  let remaining = command;
  let next = peelOneSilentTrailer(remaining);
  while (next !== remaining) {
    if (next === null) {
      return null;
    }
    remaining = next;
    next = peelOneSilentTrailer(remaining);
  }
  return remaining;
}

/** Leftover `;` / `&&` / `||` / `&` ⇒ non-silent trailer or compound command. */
function hasUnsafeShellTrailer(statement) {
  if (/[;\n]/.test(statement)) {
    return true;
  }
  if (/&&/.test(statement)) {
    return true;
  }
  if (/\|\|/.test(statement)) {
    return true;
  }
  return /(?:^|[^&])&(?:[^&>]|$)/.test(statement);
}

/**
 * Reduce a shell command to a single hook invocation, or null if trailers
 * could write stdout and corrupt the structured JSON payload.
 */
function coreShellInvocation(command) {
  // Controls and non-shell whitespace would be trimmed away before parsing.
  if (typeof command !== 'string'
    || /[\x00-\x08\x0a-\x1f\x7f]|[^\S \t]/.test(command)) {
    return null;
  }
  const trimmed = command.trim();
  if (!trimmed) {
    return null;
  }
  const peeled = peelSilentTrailers(trimmed);
  if (!peeled) {
    return null;
  }
  if (hasUnsafeShellTrailer(peeled)) {
    return null;
  }
  return peeled;
}

function shellCommandInvokesSuggestCompact(command, rootDir) {
  if (!textMentionsSuggestCompactScript(command)) {
    return false;
  }
  const core = coreShellInvocation(command);
  if (!core) {
    return false;
  }
  return shellStatementInvokesSuggestCompact(core, rootDir);
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
    // nosemgrep: javascript.lang.security.audit.detect-non-literal-regexp.detect-non-literal-regexp -- operator hooks.json matcher, tested only against the literals Edit/Write
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
  // args present => exec-form spawn; never shell-parse command (ADR 0049).
  if (Array.isArray(hook.args)) {
    return execArgvInvokesSuggestCompact(hookArgvTokens(hook), false, false, rootDir);
  }
  return shellCommandInvokesSuggestCompact(hook.command, rootDir);
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
