#!/usr/bin/env node

const { spawnSync } = require('child_process');
const path = require('path');
const { listAvailableLanguages } = require('./lib/install-executor');

const COMMANDS = {
  install: {
    script: 'install-apply.js',
    description: 'Install ECC content into a supported target',
  },
  plan: {
    script: 'install-plan.js',
    description: 'Inspect selective-install manifests and resolved plans',
  },
  catalog: {
    script: 'catalog.js',
    description: 'Discover install profiles and component IDs',
  },
  consult: {
    script: 'consult.js',
    description: 'Recommend ECC components and profiles from a natural language query',
  },
  'install-plan': {
    script: 'install-plan.js',
    description: 'Alias for plan',
  },
  'list-installed': {
    script: 'list-installed.js',
    description: 'Inspect install-state files for the current context',
  },
  doctor: {
    script: 'doctor.js',
    description: 'Diagnose missing or drifted ECC-managed files',
  },
  repair: {
    script: 'repair.js',
    description: 'Restore drifted or missing ECC-managed files',
  },
  'auto-update': {
    script: 'auto-update.js',
    description: 'Pull latest ECC changes and reinstall the current managed targets',
  },
  status: {
    script: 'status.js',
    description: 'Query the ECC SQLite state store status summary',
  },
  'platform-audit': {
    script: 'platform-audit.js',
    description: 'Audit GitHub queues, discussions, roadmap, release, and security evidence',
  },
  'security-ioc-scan': {
    script: 'ci/scan-supply-chain-iocs.js',
    description: 'Scan dependency and AI-tool persistence surfaces for active supply-chain IOCs',
  },
  sessions: {
    script: 'sessions-cli.js',
    description: 'List or inspect ECC sessions from the SQLite state store',
  },
  'work-items': {
    script: 'work-items.js',
    description: 'Track linked Linear, GitHub, handoff, and manual work items',
  },
  'session-inspect': {
    script: 'session-inspect.js',
    description: 'Emit canonical ECC session snapshots from dmux or Claude history targets',
  },
  'loop-status': {
    script: 'loop-status.js',
    description: 'Inspect Claude transcripts for stale loop wakeups and pending tool results',
  },
  uninstall: {
    script: 'uninstall.js',
    description: 'Remove ECC-managed files recorded in install-state',
  },
};

const PRIMARY_COMMANDS = [
  'install',
  'plan',
  'catalog',
  'consult',
  'list-installed',
  'doctor',
  'repair',
  'auto-update',
  'status',
  'platform-audit',
  'security-ioc-scan',
  'sessions',
  'work-items',
  'session-inspect',
  'loop-status',
  'uninstall',
];

function showHelp(exitCode = 0) {
  console.log(`
ECC selective-install CLI

Usage:
  ecc <command> [args...]
  ecc [install args...]
  ecc --dry-run <command> [args...]

Commands:
${PRIMARY_COMMANDS.map(command => `  ${command.padEnd(15)} ${COMMANDS[command].description}`).join('\n')}

Compatibility:
  ecc-install        Legacy install entrypoint retained for existing flows
  ecc [args...]      Without a command, args are routed to "install"
  ecc help <command> Show help for a specific command

Global Flags:
  --dry-run          Preview actions without executing (sets ECC_DRY_RUN=1)

Examples:
  ecc typescript
  ecc install --profile developer --target claude
  ecc plan --profile core --target cursor
  ecc catalog profiles
  ecc catalog components --family language
  ecc catalog show framework:nextjs
  ecc consult "security reviews"
  ecc list-installed --json
  ecc doctor --target cursor
  ecc repair --dry-run
  ecc auto-update --dry-run
  ecc status --json
  ecc status --exit-code
  ecc status --markdown --write status.md
  ecc platform-audit --json --allow-untracked docs/drafts/
  ecc security-ioc-scan --home
  ecc sessions
  ecc sessions session-active --json
  ecc work-items upsert linear-ecc-20 --source linear --source-id ECC-20 --title "Review control-plane contract" --status blocked
  ecc work-items sync-github --repo affaan-m/ECC
  ecc session-inspect claude:latest
  ecc loop-status --json
  ecc uninstall --target antigravity --dry-run
`);

  process.exit(exitCode);
}

function resolveCommand(argv) {
  const args = argv.slice(2);

  if (args.length === 0) {
    return { mode: 'help' };
  }

  // `--dry-run` is a global flag (documented as `ecc --dry-run <command>`).
  // Normalize it: set ECC_DRY_RUN, then strip it from positional parsing so it
  // is never mistaken for the command name (e.g. `ecc help --dry-run doctor`
  // must resolve to `doctor`, not throw on `--dry-run`). It is re-forwarded to
  // mutating subcommands below.
  const dryRun = args.includes('--dry-run');
  if (dryRun) {
    process.env.ECC_DRY_RUN = '1';
  }
  const cleanArgs = args.filter(arg => arg !== '--dry-run');

  if (cleanArgs.length === 0) {
    return { mode: 'help' };
  }

  const firstArg = cleanArgs[0];
  const restArgs = cleanArgs.slice(1);

  if (firstArg === '--help' || firstArg === '-h') {
    return { mode: 'help' };
  }

  if (firstArg === 'help') {
    return {
      mode: 'help-command',
      command: restArgs[0] || null,
    };
  }

  // Mutating subcommands parse their OWN --dry-run argv flag and do NOT read
  // ECC_DRY_RUN, so a global `ecc --dry-run <cmd>` must forward the flag or the
  // destructive action would execute instead of preview. Read-only commands
  // rely on ECC_DRY_RUN and may reject an unknown flag, so only forward here.
  const DRY_RUN_ARGV_COMMANDS = new Set(['install', 'repair', 'uninstall', 'auto-update']);

  if (COMMANDS[firstArg]) {
    const forwardDryRun = dryRun && DRY_RUN_ARGV_COMMANDS.has(firstArg);
    return {
      mode: 'command',
      command: firstArg,
      args: forwardDryRun ? ['--dry-run', ...restArgs] : restArgs,
    };
  }

  const knownLegacyLanguages = listAvailableLanguages();
  const shouldTreatAsImplicitInstall = (
    firstArg.startsWith('-')
    || knownLegacyLanguages.includes(firstArg)
  );

  if (!shouldTreatAsImplicitInstall) {
    throw new Error(`Unknown command: ${firstArg}`);
  }

  // Implicit install (e.g. `ecc typescript`, `ecc --profile x`) — install
  // parses its own --dry-run flag, so forward it on the cleaned args.
  return {
    mode: 'command',
    command: 'install',
    args: dryRun ? ['--dry-run', ...cleanArgs] : cleanArgs,
  };
}

function runCommand(commandName, args) {
  const command = COMMANDS[commandName];
  if (!command) {
    throw new Error(`Unknown command: ${commandName}`);
  }

  const result = spawnSync(
    process.execPath,
    [path.join(__dirname, command.script), ...args],
    {
      cwd: process.cwd(),
      env: process.env,
      encoding: 'utf8',
      maxBuffer: 10 * 1024 * 1024,
    }
  );

  if (result.error) {
    throw result.error;
  }

  if (result.stdout) {
    process.stdout.write(result.stdout);
  }

  if (result.stderr) {
    process.stderr.write(result.stderr);
  }

  if (typeof result.status === 'number') {
    return result.status;
  }

  if (result.signal) {
    throw new Error(`Command "${commandName}" terminated by signal ${result.signal}`);
  }

  return 1;
}

function main() {
  try {
    const resolution = resolveCommand(process.argv);

    if (resolution.mode === 'help') {
      showHelp(0);
    }

    if (resolution.mode === 'help-command') {
      if (!resolution.command) {
        showHelp(0);
      }

      if (!COMMANDS[resolution.command]) {
        throw new Error(`Unknown command: ${resolution.command}`);
      }

      process.exitCode = runCommand(resolution.command, ['--help']);
      return;
    }

    process.exitCode = runCommand(resolution.command, resolution.args);
  } catch (error) {
    console.error(`Error: ${error.message}`);
    process.exit(1);
  }
}

main();
