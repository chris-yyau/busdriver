#!/usr/bin/env node
/**
 * Model-route policy contract (ADR 0046 — Opus-only Claude work routes).
 *
 * ONE check owns model policy for agent production metadata. `validate-agents.js`
 * keeps required-field/duplicate validation for `agents/` and no longer carries a
 * VALID_MODELS list — the policy moved here rather than being duplicated.
 *
 * Scope, stated honestly: this binds agent METADATA (`agents/*.md` and
 * `skills/<skill>/agents/[name].md`). It does not police executable defaults in scripts or
 * skills — `.upstream-sources.json` provenance is what protects those (ADR 0046 KD7).
 *
 * Fail-closed shape: a CLOSED whitelist, never a sonnet/haiku denylist. `opus` is
 * accepted; `fable` only for an allowlisted path that ALSO proves read-only
 * capability. Everything else — a versioned id (`claude-sonnet-5`), a
 * provider-prefixed id, another vendor, a typo, a missing pin — is rejected.
 */

const fs = require('fs');
const path = require('path');
const { extractFrontmatter } = require('./validate-agents.js');

const ROOT = path.join(__dirname, '../..');

// Paths (repo-relative) permitted to pin `fable`. Ships EMPTY and frozen: no live
// agent pins fable. Adding one requires a code change here AND a read-only
// `tools:` line that passes the capability check below.
const FABLE_ALLOWED = Object.freeze([]);

// Positive allowlist. A denylist of mutation tools would be outrun by the next
// plugin-provided or newly added write tool; this cannot be.
const READ_ONLY_TOOLS = new Set(['Read', 'Grep', 'Glob', 'WebFetch', 'WebSearch']);

// Closed set; `xhigh`/`max` are deliberately absent for fable agents so this check
// cannot pass a file that tests/test-agent-effort-tiers.sh invariant (iv) fails.
const FABLE_EFFORTS = new Set(['low', 'medium', 'high']);

// Selects the ERROR MESSAGE only — never the verdict, which is the closed whitelist.
const WEAKER_FAMILY = /(^|[-.])(sonnet|haiku)([-.]|$)/i;

/** Discover agent files: agents/*.md plus skills/<skill>/agents/*.md. */
function discoverAgentFiles(rootDir) {
  const found = [];
  const pushDir = dir => {
    if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) return;
    for (const f of fs.readdirSync(dir).sort()) {
      // `f` is a readdirSync entry name (never a path), and `dir` derives from
      // rootDir: the repo root, or a test-owned temp dir. Not user input.
      // nosemgrep: javascript.lang.security.audit.path-traversal.path-join-resolve-traversal.path-join-resolve-traversal
      if (f.endsWith('.md')) found.push(path.join(dir, f));
    }
  };
  // nosemgrep: javascript.lang.security.audit.path-traversal.path-join-resolve-traversal.path-join-resolve-traversal
  pushDir(path.join(rootDir, 'agents'));
  // nosemgrep: javascript.lang.security.audit.path-traversal.path-join-resolve-traversal.path-join-resolve-traversal
  const skillsDir = path.join(rootDir, 'skills');
  if (fs.existsSync(skillsDir)) {
    for (const skill of fs.readdirSync(skillsDir).sort()) {
      // `skill` is a readdirSync entry name under the repo's own skills/ dir.
      // nosemgrep: javascript.lang.security.audit.path-traversal.path-join-resolve-traversal.path-join-resolve-traversal
      pushDir(path.join(skillsDir, skill, 'agents'));
    }
  }
  return found;
}

/**
 * Parse a frontmatter `tools:` value into tokens.
 *
 * All live `tools:` lines are bracketed YAML arrays (quoted or bare), and
 * extractFrontmatter hands back the literal text including brackets. Returns null
 * for anything the grammar cannot parse — a null is a REJECTION, never a pass:
 * an omitted or indented `tools:` means inherited full access, so treating it as
 * "no mutation tools" would invert the fail-closed default.
 */
function parseTools(raw) {
  if (typeof raw !== 'string') return null;
  let v = raw.trim();
  if (!v) return null;
  if (v.startsWith('[')) {
    if (!v.endsWith(']')) return null;
    v = v.slice(1, -1);
  }
  const tokens = [];
  for (let tok of v.split(',')) {
    tok = tok.trim();
    if (tok.length >= 2 && /^["']/.test(tok) && tok[0] === tok[tok.length - 1]) {
      tok = tok.slice(1, -1).trim();
    }
    if (!tok || /["'\[\]]/.test(tok)) return null;
    tokens.push(tok);
  }
  return tokens.length ? tokens : null;
}

/**
 * Load and resolve the `model:` value for one agent file.
 *
 * @returns {{error: string}|{model: string, fm: object}} an error string means
 *   the file is already fully classified (unreadable, no frontmatter, duplicate
 *   'model' key, or missing 'model') and the caller should record it and move on.
 */
function loadModel(file, rel) {
  let fm;
  try {
    fm = extractFrontmatter(fs.readFileSync(file, 'utf-8'));
  } catch (err) {
    return { error: `${rel} - unreadable: ${err.message}` };
  }
  if (!fm) {
    return { error: `${rel} - missing frontmatter` };
  }
  if (fm.__duplicates__.includes('model')) {
    return { error: `${rel} - duplicate 'model' key: last-wins parsing must not decide a fail-closed check` };
  }

  const model = (fm.model || '').trim();
  if (!model) {
    return { error: `${rel} - missing 'model'. An unpinned agent inherits the session model; every Claude work route must pin 'opus' (ADR 0046)` };
  }
  return { model, fm };
}

/** Validate a fable agent's `tools:` line is single-line, parseable, and read-only. */
function checkFableTools(rel, fm) {
  const tools = parseTools(fm.tools);
  if (!tools) {
    return [`${rel} - fable agent needs a single-line, parseable, non-empty 'tools:'. Missing/empty/indented means INHERITED FULL ACCESS, not read-only`];
  }
  const bad = tools.filter(t => !READ_ONLY_TOOLS.has(t));
  if (!bad.length) return [];
  return [`${rel} - fable agent may not hold ${bad.join(', ')}. Allowed: ${[...READ_ONLY_TOOLS].join(', ')}`];
}

/** Validate a `model: fable` agent's allowlist membership and read-only capability. */
function checkFableAgent(rel, fm, fableAllowed) {
  const errors = [];
  if (!fableAllowed.has(rel)) {
    errors.push(`${rel} - 'fable' is not permitted here. Add the path to FABLE_ALLOWED in scripts/ci/validate-model-routes.js only for a non-implementation plan/spec/advisory agent`);
    return errors;
  }
  for (const key of ['tools', 'effort']) {
    if (fm.__duplicates__.includes(key)) {
      errors.push(`${rel} - duplicate '${key}' key on a fable agent`);
    }
  }
  errors.push(...checkFableTools(rel, fm));
  const effort = (fm.effort || '').trim();
  if (!FABLE_EFFORTS.has(effort)) {
    errors.push(`${rel} - fable agent needs an explicit 'effort:' of ${[...FABLE_EFFORTS].join('|')} (got '${effort || '<missing>'}'), so it cannot pass here and fail tests/test-agent-effort-tiers.sh invariant (iv)`);
  }
  return errors;
}

/**
 * Classify a single discovered agent file against the model-route policy.
 * @returns {string[]} zero or more error strings for this file
 */
function classifyAgentFile(file, rootDir, fableAllowed) {
  const rel = path.relative(rootDir, file).split(path.sep).join('/');
  const loaded = loadModel(file, rel);
  if (loaded.error) return [loaded.error];

  const { model, fm } = loaded;
  if (model === 'opus') return [];

  if (model !== 'fable') {
    const why = WEAKER_FAMILY.test(model)
      ? `'${model}' is a weaker Claude tier`
      : `'${model}' is not an accepted model`;
    return [`${rel} - ${why}. Claude work routes must pin 'opus' (ADR 0046); 'fable' is allowed only for an allowlisted read-only advisory agent`];
  }

  // model === 'fable' from here.
  return checkFableAgent(rel, fm, fableAllowed);
}

/**
 * @param {{rootDir?: string, fableAllowed?: string[], files?: string[]}} opts
 *   `files`, when given, is used instead of re-discovering agent files — callers
 *   that already discovered them (e.g. the CLI entry point below, for its summary
 *   count) can avoid walking the tree twice. Not part of the public test surface.
 * @returns {string[]} error strings; empty means the policy holds
 */
function validateModelRoutes(opts = {}) {
  const rootDir = opts.rootDir || ROOT;
  const fableAllowed = new Set(opts.fableAllowed || FABLE_ALLOWED);
  const errors = [];

  for (const file of opts.files || discoverAgentFiles(rootDir)) {
    errors.push(...classifyAgentFile(file, rootDir, fableAllowed));
  }

  return errors;
}

if (require.main === module) {
  const discovered = discoverAgentFiles(ROOT);
  const errors = validateModelRoutes({ files: discovered });
  for (const e of errors) console.error(`ERROR: ${e}`);
  if (errors.length) process.exit(1);
  console.log(`Validated model routes for ${discovered.length} agent files`);
}

module.exports = { validateModelRoutes, discoverAgentFiles, parseTools, FABLE_ALLOWED };
