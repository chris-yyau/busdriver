#!/usr/bin/env node
/**
 * Validate hooks.json schema and hook entry rules.
 */

const fs = require('fs');
const { spawnSync } = require('child_process');
const path = require('path');
const vm = require('vm');
const Ajv = require('ajv');

// Single-pass unescape for inline `node -e "..."` payloads. A sequential
// .replace() chain double-unescapes (e.g. `\\n` -> `\n` -> newline); matching a
// backslash plus one following char consumes each backslash exactly once. The
// capture regex below guarantees every backslash is followed by a char, so there
// is no lone trailing backslash to mishandle.
function unescapeInlineJs(s) {
  return s.replace(/\\(.)/g, (_, c) => {
    switch (c) {
      case 'n': return '\n';
      case 't': return '\t';
      case '\\': return '\\';
      case '"': return '"';
      default: return '\\' + c; // preserve unknown escapes verbatim
    }
  });
}

// Optional argv override so the launch-form pins can be exercised against mutated
// COPIES instead of by editing the real document in place. CI invokes with no args.
const HOOKS_FILE = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.join(__dirname, '../../hooks/hooks.json');
const HOOKS_SCHEMA_PATH = path.join(__dirname, '../../schemas/hooks.schema.json');
const VALID_EVENTS = [
  'SessionStart',
  'UserPromptSubmit',
  'PreToolUse',
  'PermissionRequest',
  'PostToolUse',
  'PostToolUseFailure',
  'Notification',
  'SubagentStart',
  'Stop',
  'SubagentStop',
  'PreCompact',
  'InstructionsLoaded',
  'TeammateIdle',
  'TaskCompleted',
  'ConfigChange',
  'WorktreeCreate',
  'WorktreeRemove',
  'SessionEnd',
];
const VALID_HOOK_TYPES = ['command', 'http', 'prompt', 'agent'];
const EVENTS_WITHOUT_MATCHER = new Set(['UserPromptSubmit', 'Notification', 'Stop', 'SubagentStop']);

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function isNonEmptyStringArray(value) {
  return Array.isArray(value) && value.length > 0 && value.every(item => isNonEmptyString(item));
}

// ── #713: the contained-gate launch form is pinned here, fail-CLOSED ──────────────
// A committed `.claude/settings.json` `env` block reaches the outer `/bin/sh -c` that a
// SHELL-FORM hook runs under, so `SHELLOPTS=noexec` makes that shell parse the command and
// exit 0 without executing it — silencing `env -i`, the wrapper and the gate together
// (measured; see docs/adr/0049 and issue #713). Exec form (`command` + `args`) is spawned
// as a direct argv with no shell, which is the only thing that closes it.
//
// This is a GATE, not a style rule: a registration that reverts to a command string, drops
// `-i`, or smuggles an extra assignment between `-i` and `/bin/bash` re-poisons the very
// bash that `env -i` exists to sterilize. Anything not provably safe fails CI.
const CONTAINED_WRAPPERS = ['sanitized-gate.sh', 'sanitized-node.sh'];
// The first hop. `command` must NEVER be bare `/usr/bin/env` again: a client that honours
// `command` but drops `args` then runs `env` with no operands, and bare `env` EXITS 0 AND
// PRINTS THE ENVIRONMENT — an allow on every gate plus a per-event environment dump (R7).
// contained-launch.sh exits 2 with no stdout in that shape, and converts a launch failure
// that produced no decision into the registration's declared disposition (R8).
const CONTAINED_LAUNCHER = '${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/contained-launch.sh';
// First arg: which way this registration fails when the wrapper never answers. `open` is
// only for the two GateGuard rows that carried `|| exit 0` before #713.
const DISPOSITIONS = new Set(['closed', 'open']);
const EXPECTED_OPEN_DISPOSITION = 2;
let openDispositionSeen = 0;
// The only two legal wrapper operands, pinned in full. A `startsWith('${CLAUDE_PLUGIN_ROOT}/')`
// prefix check is not enough: detection is a SUBSTRING match, so
// `…/lib/sanitized-node.sh.disabled` would still be counted as a contained gate, still pass
// the grammar, and still fail to launch — bash exits 127, which does not block (R8). Pinning
// the whole string makes "counted" and "launchable" the same predicate.
const CONTAINED_WRAPPER_PATHS = new Set(CONTAINED_WRAPPERS.map(
  w => `\${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/${w}`));
// The number of contained registrations, pinned. Detection alone is SELF-SELECTING: a
// mutation that removes the wrapper reference (reverting to shell form, or repointing the
// operand at another path) also removes the registration from the population the grammar
// guards, so the grammar would pass by vacuum. The count is what makes the pin fail-closed.
// Changing it is a deliberate, reviewed act — see docs/adr/0049 and #713.
const EXPECTED_CONTAINED = 19;
let containedSeen = 0;
// Of those, how many are exec form vs. deliberately left in shell form. Two registrations
// are NOT migrated: the Codex nudges POST `@codex review` comments and are suppressed by
// `$PR_GRIND_CODEX_RETRIGGER`, which exec form cannot forward (`env -i` strips it, and the
// nudge runs its delegate as a CHILD of that sterile process). Both are non-gating, so an
// outer-shell SHELLOPTS=noexec silencing them skips a nudge rather than bypassing a gate —
// the trade Hermes took in #713 rather than silently re-enabling an outbound side effect.
// They are pinned VERBATIM below, not by grammar: a substring-keyed exemption would be the
// same self-selecting hole the count above exists to close.
const EXPECTED_EXEC_FORM = 17;
const EXPECTED_SHELL_EXEMPT = 2;
let execFormSeen = 0;
let shellExemptSeen = 0;
// The exact roster, `<event>|<gate identity>`. Counts alone are not enough: they say how
// many contained registrations exist, never WHICH, so swapping `pre-pr-gate.sh` for a
// second `careful-guard.sh` — or moving a gate to an event that never fires for it —
// preserves 17/2 and disables a gate silently. Sorted so block order stays free to change.
const EXPECTED_ROSTER = [
  "PostToolUseFailure|mcp__.*|t=undefined|post:mcp-health-check scripts/hooks/mcp-health-check.js standard,strict",
  "PostToolUse|Bash|t=15|post-merge-confirm-bypass.sh",
  "PostToolUse|Bash|t=20|codex-nudge-precreate.sh",
  "PostToolUse|Bash|t=5|post-commit-consume-marker.sh",
  "PostToolUse|Bash|t=5|post-pr-consume-marker.sh",
  "PostToolUse|Write|Edit|MultiEdit|Bash|t=5|check-design-document.sh",
  "PreToolUse|Bash|t=10|careful-guard.sh",
  "PreToolUse|Bash|t=10|pre-commit-gate.sh",
  "PreToolUse|Bash|t=10|pre-pr-gate.sh",
  "PreToolUse|Bash|t=20|codex-nudge-premerge.sh",
  "PreToolUse|Bash|t=20|pre-merge-gate.sh",
  "PreToolUse|Bash|t=undefined|--fail-open pre:bash:gateguard-fact-force scripts/hooks/gateguard-fact-force.js minimal,standard,strict",
  "PreToolUse|Bash|t=undefined|pre:bash:block-no-verify scripts/hooks/block-no-verify.js standard,strict",
  "PreToolUse|Bash|t=undefined|pre:bash:dev-server-block scripts/hooks/pre-bash-dev-server-block.js standard,strict",
  "PreToolUse|Write|Edit|MultiEdit|Bash|t=5|pre-implementation-gate.sh",
  "PreToolUse|Write|Edit|MultiEdit|t=30|pre:config-protection scripts/hooks/config-protection.js standard,strict",
  "PreToolUse|Write|Edit|MultiEdit|t=3|freeze-guard.sh",
  "PreToolUse|Write|Edit|MultiEdit|t=undefined|--fail-open pre:edit-write:gateguard-fact-force scripts/hooks/gateguard-fact-force.js minimal,standard,strict",
  "PreToolUse|mcp__.*|t=undefined|pre:mcp-health-check scripts/hooks/mcp-health-check.js standard,strict",
];
const rosterSeen = [];
const SHELL_FORM_EXEMPT = new Map([
  ['codex-nudge-premerge.sh',
    '/usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" PR_GRIND_CODEX_RETRIGGER="${PR_GRIND_CODEX_RETRIGGER:-}" PR_GRIND_CODEX_RETRIGGER_MAX="${PR_GRIND_CODEX_RETRIGGER_MAX:-}" PR_GRIND_CODEX_RETRIGGER_COOLDOWN="${PR_GRIND_CODEX_RETRIGGER_COOLDOWN:-}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/sanitized-gate.sh" codex-nudge-premerge.sh'],
  ['codex-nudge-precreate.sh',
    '/usr/bin/env -i PATH=/usr/bin:/bin HOME="$HOME" CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}" PR_GRIND_CODEX_RETRIGGER="${PR_GRIND_CODEX_RETRIGGER:-}" PR_GRIND_CODEX_RETRIGGER_MAX="${PR_GRIND_CODEX_RETRIGGER_MAX:-}" PR_GRIND_CODEX_RETRIGGER_COOLDOWN="${PR_GRIND_CODEX_RETRIGGER_COOLDOWN:-}" bash "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/sanitized-gate.sh" codex-nudge-precreate.sh'],
]);
// Only these may appear as `NAME=value` between `-i` and `/bin/bash`. Deliberately tiny:
// every name here is a value a hostile repo could once set through the session env.
//
// The VALUE is pinned too, not just the name. Allowlisting names alone would accept
// `CLAUDE_PLUGIN_ROOT=/not-the-plugin`, which passes every count and every grammar check
// while pointing the wrapper at an attacker-chosen tree — and the wrapper's own refusal
// path exits 1, which does NOT block (only exit 2 does), so the gate would be silently
// disabled rather than fail closed.
//
// `:timeout` means "must equal this registration's own `timeout`". CODEX_WARN_OUTER_BUDGET
// is the budget `codex_none_warning` reserves INSIDE the hook's outer cap; ADR 0024 keeps
// the two co-located so they cannot drift, but co-location is a convention until something
// checks it — a `timeout` lowered to 5 against a budget of 20 lets the advisory overrun the
// cap and the harness kill an authorized merge.
const TIMEOUT_SENTINEL = ':timeout';
const ALLOWED_ASSIGNMENTS = new Map([
  ['CLAUDE_PLUGIN_ROOT', '${CLAUDE_PLUGIN_ROOT}'],
  ['CODEX_WARN_OUTER_BUDGET', TIMEOUT_SENTINEL],
]);
// Gates that MUST carry a given assignment. Without this the allowlist is one-directional:
// dropping CODEX_WARN_OUTER_BUDGET entirely would pass, and the advisory would silently
// fall back to its `:-20` default while the registration's timeout said otherwise.
const REQUIRED_ASSIGNMENTS = new Map([['pre-merge-gate.sh', ['CODEX_WARN_OUTER_BUDGET']]]);
// Required on EVERY contained registration: the wrapper resolves the gate it runs relative
// to $CLAUDE_PLUGIN_ROOT, so dropping the assignment leaves it unresolvable and the wrapper
// exits 1 — which does NOT block. Silently disabled, not fail-closed.
const REQUIRED_EVERYWHERE = ['CLAUDE_PLUGIN_ROOT'];

// The operands AFTER the wrapper path. Pinning the launch form but not its arguments leaves
// a gap the population counts cannot see: deleting the trailing gate name keeps the wrapper
// reference (so the row is still counted) and still satisfies every grammar rule above,
// while the wrapper itself exits 1 on the missing operand — non-blocking, i.e. the gate is
// off. Shapes mirror the wrappers' own argument contracts.
const WRAPPER_OPERANDS = {
  'sanitized-gate.sh': (ops, fail) => {
    if (ops.length !== 1) {
      fail(`sanitized-gate.sh takes exactly one operand (the gate script); got ${ops.length}: ` +
           `${JSON.stringify(ops)} — a wrong count makes the wrapper exit 1, which does not block`);
      return;
    }
    if (!/^[A-Za-z0-9._-]+\.sh$/.test(ops[0])) {
      fail(`sanitized-gate.sh operand ${JSON.stringify(ops[0])} is not a plain <gate>.sh basename`);
    }
  },
  'sanitized-node.sh': (ops, fail) => {
    const rest = ops[0] === '--fail-open' ? ops.slice(1) : ops;
    if (rest.length !== 3) {
      fail('sanitized-node.sh takes [--fail-open] <hookId> <scriptRelPath> <profilesCsv>; got ' +
           `${JSON.stringify(ops)} — a wrong count makes the wrapper exit 1, which does not block`);
      return;
    }
    const [hookId, script, profiles] = rest;
    if (!/^[a-z0-9:._-]+$/.test(hookId)) fail(`hookId ${JSON.stringify(hookId)} has an unexpected shape`);
    if (!/^scripts\/hooks\/[A-Za-z0-9._-]+\.js$/.test(script)) {
      fail(`runner ${JSON.stringify(script)} must be a scripts/hooks/*.js path`);
    }
    if (!/^[a-z]+(,[a-z]+)*$/.test(profiles)) fail(`profiles ${JSON.stringify(profiles)} is not a csv of names`);
  },
};

function validateContainedLaunch(hook, label, eventType, matcher) {
  const argv = [hook.command, ...(Array.isArray(hook.args) ? hook.args : [])];
  const names = argv.filter(a => typeof a === 'string');
  if (!names.some(a => CONTAINED_WRAPPERS.some(w => a.includes(w)))) {
    return false; // not a contained registration — nothing to pin
  }
  containedSeen += 1;

  let hasErrors = false;
  const fail = msg => { console.error(`ERROR: ${label} ${msg}`); hasErrors = true; };

  // The two shell-form exemptions, matched VERBATIM against a frozen literal. Exact match
  // subsumes the grammar: it pins every forwarded knob, refuses a one-character drift, and
  // cannot be claimed by any other registration.
  const event = eventType || String(label).split('[')[0];
  // The roster key carries the MATCHER too: a gate re-pointed at a tool it never sees is
  // as disabled as a deleted one, and every count stays identical.
  // …and the TIMEOUT: a gate given `timeout: 0` is killed before it can decide, which is
  // indistinguishable from deleting it and leaves every count and every shape rule intact.
  const scope = `${event}|${typeof matcher === 'string' ? matcher : JSON.stringify(matcher ?? null)}` +
    `|t=${hook.timeout}`;
  const exemptKey = [...SHELL_FORM_EXEMPT.keys()].find(k => names.some(a => a.includes(k)));
  if (exemptKey) {
    shellExemptSeen += 1;
    rosterSeen.push(`${scope}|${exemptKey}`);
    if ('args' in hook) {
      fail(`${exemptKey} is a deliberate shell-form exemption and must not carry \`args\`: exec form strips $PR_GRIND_CODEX_RETRIGGER and re-enables outbound @codex comments (#713 / ADR 0049)`);
    } else if (hook.command !== SHELL_FORM_EXEMPT.get(exemptKey)) {
      fail(`${exemptKey} must match its pinned shell-form command VERBATIM (#713 / ADR 0049); got ${JSON.stringify(hook.command)}`);
    }
    return hasErrors;
  }
  execFormSeen += 1;

  if (hook.command === '/usr/bin/env') {
    fail('contained gate must not name bare "/usr/bin/env" as `command`: a client that drops ' +
         '`args` then runs env with no operands, which exits 0 and prints the environment — #713 / R7');
    return true;
  }
  if (hook.command !== CONTAINED_LAUNCHER) {
    fail(`contained gate must launch through ${CONTAINED_LAUNCHER} ` +
         `(got ${JSON.stringify(hook.command)}) — #713`);
    return true; // the rest of the grammar is meaningless without this
  }
  const args = Array.isArray(hook.args) ? hook.args : null;
  if (!args) {
    fail('contained gate must use exec form (`args` array); a command string is re-silenceable — #713');
    return true;
  }
  if (!DISPOSITIONS.has(args[0])) {
    fail(`first arg must be the launch-failure disposition (${[...DISPOSITIONS].join('|')}), got ` +
         `${JSON.stringify(args[0])} — the launcher needs it to turn a 127 into a block (#713 / R8)`);
    return true;
  }
  if (args[0] === 'open') openDispositionSeen += 1;
  if (args[1] !== 'PATH=/usr/bin:/bin') fail('contained gate must pin PATH=/usr/bin:/bin as the second arg');

  const bashAt = args.indexOf('/bin/bash');
  if (bashAt < 2) {
    fail('contained gate must invoke `/bin/bash` by absolute path after the assignments');
    return true;
  }
  const seenAssignments = new Set();
  for (const assignment of args.slice(2, bashAt)) {
    const eq = assignment.indexOf('=');
    const name = eq === -1 ? assignment : assignment.slice(0, eq);
    if (eq === -1) {
      fail(`unexpected non-assignment ${JSON.stringify(assignment)} before /bin/bash`);
      continue;
    }
    if (!ALLOWED_ASSIGNMENTS.has(name)) {
      fail(`assignment ${name}= is not on the contained-launch allowlist (#713)`);
      continue;
    }
    if (seenAssignments.has(name)) {
      // A repeat is always drift: `env` takes the LAST occurrence, so a duplicate is either
      // dead weight or a silent override the value pin above would only catch by luck.
      fail(`assignment ${name}= appears more than once before /bin/bash (#713)`);
    }
    seenAssignments.add(name);
    let expected = ALLOWED_ASSIGNMENTS.get(name);
    if (expected === TIMEOUT_SENTINEL) expected = String(hook.timeout);
    if (assignment.slice(eq + 1) !== expected) {
      fail(`assignment ${JSON.stringify(assignment)} must have the value ` +
           `${JSON.stringify(expected)} — the allowlist pins values, not just names, and ` +
           `${name} must track this registration's own timeout (#713 / ADR 0024)`);
    }
  }
  for (const name of REQUIRED_EVERYWHERE) {
    if (!seenAssignments.has(name)) {
      fail(`every contained registration must carry ${name}= (without it the wrapper cannot ` +
           'resolve its gate and exits 1, which does not block — #713)');
    }
  }
  for (const [gate, required] of REQUIRED_ASSIGNMENTS) {
    if (!args.includes(gate)) continue;
    for (const name of required) {
      if (!seenAssignments.has(name)) {
        fail(`${gate} must carry ${name}= (dropping it silently falls back to a default ` +
             'that can disagree with the registration timeout — #713 / ADR 0024)');
      }
    }
  }
  // The wrapper path must be the arg right after /bin/bash, and must be plugin-rooted:
  // an unresolved or mistyped path makes bash exit 127, which does NOT block (only exit 2
  // does) — i.e. a silently disabled gate. See R8.
  const wrapper = args[bashAt + 1];
  if (typeof wrapper !== 'string' || !CONTAINED_WRAPPER_PATHS.has(wrapper)) {
    fail(`the wrapper operand must be exactly one of ${[...CONTAINED_WRAPPER_PATHS].join(' | ')} ` +
         `(got ${JSON.stringify(wrapper)}) — a near-miss path is counted but does not launch (#713 / R8)`);
  }
  const wrapperName = String(wrapper).split('/').pop();
  const operands = args.slice(bashAt + 2);
  // The launcher's disposition and the wrapper's own --fail-open flag are two spellings of
  // the same decision; letting them disagree would make the registration lie about which way
  // it fails. Only the two GateGuard rows may be open, and they must be open in both places.
  const wrapperIsOpen = operands[0] === '--fail-open';
  if (wrapperIsOpen !== (args[0] === 'open')) {
    fail(`launch disposition ${JSON.stringify(args[0])} disagrees with the wrapper flag ` +
         `(${wrapperIsOpen ? '--fail-open present' : 'no --fail-open'}) — #713 / R8`);
  }
  const operandCheck = WRAPPER_OPERANDS[wrapperName];
  if (operandCheck) operandCheck(operands, fail);
  // Identity = the WHOLE operand tail, not just the gate name. Shape-checking the profiles
  // csv only proves it is a csv; narrowing `standard,strict` to `strict` passes every shape
  // rule and quietly drops the gate for standard-profile users. Pinning the tail verbatim
  // makes the roster the single place any of it can change.
  if (operands.length) rosterSeen.push(`${scope}|${operands.join(' ')}`);

  if (args.includes('||') || args.some(a => a.startsWith('|| '))) {
    fail('exec form has no shell: a `|| exit N` tail cannot run and must not be present (#713 / R8)');
  }
  if (hook.async === true) {
    // A backgrounded hook returns status 0 with no decision — an ALLOW. That silently
    // disarms the gate while leaving the argv identical.
    fail('a contained gate must not set `async: true` (backgrounded hooks return status 0 = allow)');
  }
  return hasErrors;
}

/**
 * Validate a single hook entry has required fields and valid inline JS
 * @param {object} hook - Hook object with type and command fields
 * @param {string} label - Label for error messages (e.g., "PreToolUse[0].hooks[1]")
 * @returns {boolean} true if errors were found
 */
function validateHookEntry(hook, label, eventType, matcher) {
  let hasErrors = false;

  if (!hook.type || typeof hook.type !== 'string') {
    console.error(`ERROR: ${label} missing or invalid 'type' field`);
    hasErrors = true;
  } else if (!VALID_HOOK_TYPES.includes(hook.type)) {
    console.error(`ERROR: ${label} has unsupported hook type '${hook.type}'`);
    hasErrors = true;
  }

  if ('timeout' in hook && (typeof hook.timeout !== 'number' || hook.timeout < 0)) {
    console.error(`ERROR: ${label} 'timeout' must be a non-negative number`);
    hasErrors = true;
  }

  if (hook.type === 'command') {
    if ('async' in hook && typeof hook.async !== 'boolean') {
      console.error(`ERROR: ${label} 'async' must be a boolean`);
      hasErrors = true;
    }

    if ('args' in hook && !isNonEmptyStringArray(hook.args)) {
      console.error(`ERROR: ${label} 'args' must be a non-empty array of non-empty strings`);
      hasErrors = true;
    }

    if (validateContainedLaunch(hook, label, eventType, matcher)) {
      hasErrors = true;
    }

    if (!isNonEmptyString(hook.command) && !isNonEmptyStringArray(hook.command)) {
      console.error(`ERROR: ${label} missing or invalid 'command' field`);
      hasErrors = true;
    } else if (typeof hook.command === 'string') {
      const nodeEMatch = hook.command.match(/^node -e "((?:[^"\\]|\\.)*)"(?:\s|$)/s);
      if (nodeEMatch) {
        try {
          new vm.Script(unescapeInlineJs(nodeEMatch[1]));
        } catch (syntaxErr) {
          console.error(`ERROR: ${label} has invalid inline JS: ${syntaxErr.message}`);
          hasErrors = true;
        }
      }
    }

    return hasErrors;
  }

  if ('async' in hook) {
    console.error(`ERROR: ${label} 'async' is only supported for command hooks`);
    hasErrors = true;
  }

  if (hook.type === 'http') {
    if (!isNonEmptyString(hook.url)) {
      console.error(`ERROR: ${label} missing or invalid 'url' field`);
      hasErrors = true;
    }

    if ('headers' in hook && (typeof hook.headers !== 'object' || hook.headers === null || Array.isArray(hook.headers) || !Object.values(hook.headers).every(value => typeof value === 'string'))) {
      console.error(`ERROR: ${label} 'headers' must be an object with string values`);
      hasErrors = true;
    }

    if ('allowedEnvVars' in hook && (!Array.isArray(hook.allowedEnvVars) || !hook.allowedEnvVars.every(value => isNonEmptyString(value)))) {
      console.error(`ERROR: ${label} 'allowedEnvVars' must be an array of strings`);
      hasErrors = true;
    }

    return hasErrors;
  }

  if (!isNonEmptyString(hook.prompt)) {
    console.error(`ERROR: ${label} missing or invalid 'prompt' field`);
    hasErrors = true;
  }

  if ('model' in hook && !isNonEmptyString(hook.model)) {
    console.error(`ERROR: ${label} 'model' must be a non-empty string`);
    hasErrors = true;
  }

  return hasErrors;
}

function validateHooks() {
  if (!fs.existsSync(HOOKS_FILE)) {
    console.log('No hooks.json found, skipping validation');
    process.exit(0);
  }

  let data;
  try {
    data = JSON.parse(fs.readFileSync(HOOKS_FILE, 'utf-8'));
  } catch (e) {
    console.error(`ERROR: Invalid JSON in hooks.json: ${e.message}`);
    process.exit(1);
  }

  // Validate against JSON schema
  if (fs.existsSync(HOOKS_SCHEMA_PATH)) {
    const schema = JSON.parse(fs.readFileSync(HOOKS_SCHEMA_PATH, 'utf-8'));
    const ajv = new Ajv({ allErrors: true });
    const validate = ajv.compile(schema);
    const valid = validate(data);
    if (!valid) {
      for (const err of validate.errors) {
        console.error(`ERROR: hooks.json schema: ${err.instancePath || '/'} ${err.message}`);
      }
      process.exit(1);
    }
  }

  // Support both object format { hooks: {...} } and array format
  const hooks = data.hooks || data;
  let hasErrors = false;
  let totalMatchers = 0;

  if (typeof hooks === 'object' && !Array.isArray(hooks)) {
    // Object format: { EventType: [matchers] }
    for (const [eventType, matchers] of Object.entries(hooks)) {
      if (!VALID_EVENTS.includes(eventType)) {
        console.error(`ERROR: Invalid event type: ${eventType}`);
        hasErrors = true;
        continue;
      }

      if (!Array.isArray(matchers)) {
        console.error(`ERROR: ${eventType} must be an array`);
        hasErrors = true;
        continue;
      }

      for (let i = 0; i < matchers.length; i++) {
        const matcher = matchers[i];
        if (typeof matcher !== 'object' || matcher === null) {
          console.error(`ERROR: ${eventType}[${i}] is not an object`);
          hasErrors = true;
          continue;
        }
        if (!('matcher' in matcher) && !EVENTS_WITHOUT_MATCHER.has(eventType)) {
          console.error(`ERROR: ${eventType}[${i}] missing 'matcher' field`);
          hasErrors = true;
        } else if ('matcher' in matcher && typeof matcher.matcher !== 'string' && (typeof matcher.matcher !== 'object' || matcher.matcher === null)) {
          console.error(`ERROR: ${eventType}[${i}] has invalid 'matcher' field`);
          hasErrors = true;
        }
        if (!matcher.hooks || !Array.isArray(matcher.hooks)) {
          console.error(`ERROR: ${eventType}[${i}] missing 'hooks' array`);
          hasErrors = true;
        } else {
          // Validate each hook entry
          for (let j = 0; j < matcher.hooks.length; j++) {
            if (validateHookEntry(matcher.hooks[j], `${eventType}[${i}].hooks[${j}]`,
                                  eventType, matcher.matcher)) {
              hasErrors = true;
            }
          }
        }
        totalMatchers++;
      }
    }
  } else if (Array.isArray(hooks)) {
    // Array format (legacy)
    for (let i = 0; i < hooks.length; i++) {
      const hook = hooks[i];
      if (!('matcher' in hook)) {
        console.error(`ERROR: Hook ${i} missing 'matcher' field`);
        hasErrors = true;
      } else if (typeof hook.matcher !== 'string' && (typeof hook.matcher !== 'object' || hook.matcher === null)) {
        console.error(`ERROR: Hook ${i} has invalid 'matcher' field`);
        hasErrors = true;
      }
      if (!hook.hooks || !Array.isArray(hook.hooks)) {
        console.error(`ERROR: Hook ${i} missing 'hooks' array`);
        hasErrors = true;
      } else {
        // Validate each hook entry
        for (let j = 0; j < hook.hooks.length; j++) {
          if (validateHookEntry(hook.hooks[j], `Hook ${i}.hooks[${j}]`)) {
            hasErrors = true;
          }
        }
      }
      totalMatchers++;
    }
  } else {
    console.error('ERROR: hooks.json must be an object or array');
    process.exit(1);
  }

  if (containedSeen !== EXPECTED_CONTAINED) {
    console.error(
      `ERROR: expected ${EXPECTED_CONTAINED} contained gate registrations, found ${containedSeen}. ` +
      'A contained gate was added, removed, or had its wrapper reference changed — ' +
      'update EXPECTED_CONTAINED deliberately (#713).'
    );
    hasErrors = true;
  }

  const rosterActual = [...rosterSeen].sort().join('\n');
  const rosterExpected = [...EXPECTED_ROSTER].sort().join('\n');
  if (rosterActual !== rosterExpected) {
    const missing = EXPECTED_ROSTER.filter(r => !rosterSeen.includes(r));
    const extra = rosterSeen.filter(r => !EXPECTED_ROSTER.includes(r));
    console.error(
      'ERROR: the contained-gate roster changed (#713 / ADR 0049). ' +
      `Missing: ${JSON.stringify(missing)}. Unexpected: ${JSON.stringify(extra)}. ` +
      'Counts alone cannot see a gate swapped for another or moved to a different event — ' +
      'update EXPECTED_ROSTER deliberately.'
    );
    hasErrors = true;
  }

  // Hermes CLOSE_R7_AND_R8 pin: the no-argument launch is the whole R7 defence, so CI runs
  // it for real rather than trusting the source. A guard that has only been read is not a
  // guard — this one must be observed exiting 2 with an empty stdout on every CI run.
  const launcherPath = path.join(__dirname, '../../hooks/gate-scripts/lib/contained-launch.sh');
  if (!fs.existsSync(launcherPath)) {
    console.error(`ERROR: contained-launch.sh missing at ${launcherPath} — #713 / R7`);
    hasErrors = true;
  } else {
    // `-p` is load-bearing, not style: privileged mode is the only reason a bash script may
    // stand in FRONT of `env -i`. Without it bash imports exported shell functions from the
    // environment (`BASH_FUNC_printf%%` overrides the builtin), honours SHELLOPTS — so
    // xtrace plus a command-substituting PS4 executes arbitrary code — and sources BASH_ENV
    // and ENV. All three are settable from a committed .claude/settings.json `env` block.
    const shebang = String(fs.readFileSync(launcherPath, 'utf-8')).split('\n', 1)[0];
    if (shebang !== '#!/bin/bash -p') {
      console.error(
        `ERROR: contained-launch.sh must start with "#!/bin/bash -p", got ${JSON.stringify(shebang)}. ` +
        'Privileged mode is what stops the first hop importing shell functions and honouring ' +
        'SHELLOPTS/BASH_ENV/ENV from the caller — without it a bash first hop is not safe here (#713).'
      );
      hasErrors = true;
    }
    // And prove the effect, not just the spelling: an exported function overriding the
    // `printf` BUILTIN would replace the refusal message a non-privileged bash prints.
    const probe = spawnSync(launcherPath, [], {
      input: '',
      encoding: 'utf-8',
      env: { ...process.env, 'BASH_FUNC_printf%%': '() { echo LAUNCHER-NOT-PRIVILEGED; }' },
    });
    if (!probe.error && !String(probe.stderr || '').includes('contained-launch:')) {
      console.error(
        'ERROR: contained-launch.sh did not print its own refusal message under an imported ' +
        '`printf` function — the first hop is importing shell functions from the caller, ' +
        'which privileged mode must prevent (#713 / R7).'
      );
      hasErrors = true;
    }
    if (probe.error) {
      console.error(`ERROR: could not execute contained-launch.sh (${probe.error.message}) — #713 / R7`);
      hasErrors = true;
    } else if (probe.status !== 2) {
      console.error(
        `ERROR: contained-launch.sh with no arguments exited ${probe.status}, expected 2. ` +
        'That is the shape a client takes when it honours `command` and drops `args`; ' +
        'anything but 2 is an allow on every contained gate — #713 / R7.'
      );
      hasErrors = true;
    } else if (String(probe.stdout || '').length !== 0) {
      console.error(
        'ERROR: contained-launch.sh wrote to stdout with no arguments. Bare /usr/bin/env ' +
        'used to dump the environment there; the replacement must stay silent — #713 / R7.'
      );
      hasErrors = true;
    }
  }

  if (openDispositionSeen !== EXPECTED_OPEN_DISPOSITION) {
    console.error(
      `ERROR: expected ${EXPECTED_OPEN_DISPOSITION} contained registrations with the ` +
      `\`open\` launch-failure disposition, found ${openDispositionSeen}. Flipping a gate ` +
      'from closed to open makes a failed launch an ALLOW — #713 / R8.'
    );
    hasErrors = true;
  }

  // Both populations are pinned, not just the total: without this a gate could be swapped
  // into the shell-form exemption (or a nudge migrated to exec form) at a constant total.
  if (execFormSeen !== EXPECTED_EXEC_FORM || shellExemptSeen !== EXPECTED_SHELL_EXEMPT) {
    console.error(
      `ERROR: expected ${EXPECTED_EXEC_FORM} exec-form contained gates and ` +
      `${EXPECTED_SHELL_EXEMPT} pinned shell-form exemptions, found ${execFormSeen} and ` +
      `${shellExemptSeen} (#713 / ADR 0049).`
    );
    hasErrors = true;
  }

  if (hasErrors) {
    process.exit(1);
  }

  console.log(`Validated ${totalMatchers} hook matchers (${execFormSeen} contained gates via contained-launch.sh, ${shellExemptSeen} pinned shell-form exemptions; no-arg launcher probe exits 2)`);
}

if (require.main === module) {
  validateHooks();
}

module.exports = { unescapeInlineJs, validateHookEntry };
