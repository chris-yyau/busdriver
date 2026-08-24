#!/usr/bin/env node
/**
 * Validate agent markdown files have required frontmatter
 */

const fs = require('fs');
const path = require('path');

const AGENTS_DIR = path.join(__dirname, '../../agents');
const REQUIRED_FIELDS = ['model', 'tools'];
// Model-VALUE policy lives in validate-model-routes.js (ADR 0046), which also covers
// skills/*/agents/*.md. This file keeps required-field/duplicate checks for agents/.

function extractFrontmatter(content) {
  // Strip BOM if present (UTF-8 BOM: \uFEFF)
  const cleanContent = content.replace(/^\uFEFF/, '');
  // Support both LF and CRLF line endings
  const match = cleanContent.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!match) return null;

  const frontmatter = {};
  const duplicates = [];
  const lines = match[1].split(/\r?\n/);
  for (const line of lines) {
    // Only top-level keys are unique. Indented YAML belongs to nested values.
    if (/^\s/.test(line)) continue;
    const colonIdx = line.indexOf(':');
    if (colonIdx > 0) {
      const key = line.slice(0, colonIdx).trim();
      const value = line.slice(colonIdx + 1).trim();
      if (Object.prototype.hasOwnProperty.call(frontmatter, key)) {
        duplicates.push(key);
      }
      frontmatter[key] = value;
    }
  }
  Object.defineProperty(frontmatter, '__duplicates__', {
    value: duplicates,
    enumerable: false,
  });
  return frontmatter;
}

function validateAgents() {
  if (!fs.existsSync(AGENTS_DIR)) {
    console.log('No agents directory found, skipping validation');
    return true;
  }

  const files = fs.readdirSync(AGENTS_DIR).filter(f => f.endsWith('.md'));
  let hasErrors = false;

  for (const file of files) {
    const filePath = path.join(AGENTS_DIR, file);
    let content;
    try {
      content = fs.readFileSync(filePath, 'utf-8');
    } catch (err) {
      console.error(`ERROR: ${file} - ${err.message}`);
      hasErrors = true;
      continue;
    }
    const frontmatter = extractFrontmatter(content);

    if (!frontmatter) {
      console.error(`ERROR: ${file} - Missing frontmatter`);
      hasErrors = true;
      continue;
    }

    if (frontmatter.__duplicates__.length > 0) {
      console.error(`ERROR: ${file} - Duplicate frontmatter keys: ${[...new Set(frontmatter.__duplicates__)].join(', ')}`);
      hasErrors = true;
    }

    for (const field of REQUIRED_FIELDS) {
      if (!frontmatter[field] || (typeof frontmatter[field] === 'string' && !frontmatter[field].trim())) {
        console.error(`ERROR: ${file} - Missing required field: ${field}`);
        hasErrors = true;
      }
    }
  }

  console.log(`Validated ${files.length} agent files`);
  return !hasErrors;
}

if (require.main === module) {
  process.exit(validateAgents() ? 0 : 1);
}

module.exports = { extractFrontmatter, validateAgents };
