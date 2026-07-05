#!/usr/bin/env node
'use strict';

/**
 * Central runner for the CI schema/security validators.
 *
 * Runs every validator, reports each result, and exits non-zero if any fail
 * (unlike an `&&` chain, it does not stop at the first failure — so one run
 * surfaces all problems).
 *
 * check-unicode-safety.js is intentionally NOT included: on this repo it flags
 * ~900 decorative status emoji (✅ ❌ ⚠️) that skills/agents/docs use by design.
 * Narrow its threat model to genuinely-dangerous categories (bidi overrides,
 * zero-width, tag chars) before adding it here.
 */

const { execFileSync } = require('child_process');
const path = require('path');

const VALIDATORS = [
  'validate-agents.js',
  'validate-commands.js',
  'validate-hooks.js',
  'validate-skills.js',
  'validate-rules.js',
  'validate-install-manifests.js',
  'validate-no-personal-paths.js',
  'validate-workflow-security.js',
];

let failed = 0;
for (const validator of VALIDATORS) {
  const script = path.join(__dirname, validator);
  process.stdout.write(`\n── ${validator} ──\n`);
  try {
    execFileSync(process.execPath, [script], { stdio: 'inherit' });
  } catch {
    console.error(`FAIL: ${validator}`);
    failed++;
  }
}

console.log(`\n${VALIDATORS.length - failed}/${VALIDATORS.length} validators passed`);
process.exit(failed > 0 ? 1 : 0);
