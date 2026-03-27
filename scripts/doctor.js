#!/usr/bin/env node

const { buildDoctorReport } = require('./lib/install-lifecycle');
const { SUPPORTED_INSTALL_TARGETS } = require('./lib/install-manifests');

function showHelp(exitCode = 0) {
  console.log(`
Usage: node scripts/doctor.js [--target <${SUPPORTED_INSTALL_TARGETS.join('|')}>] [--json]

Diagnose drift and missing managed files for ECC install-state in the current context.
`);
  process.exit(exitCode);
}

function parseArgs(argv) {
  const args = argv.slice(2);
  const parsed = {
    targets: [],
    json: false,
    help: false,
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];

    if (arg === '--target') {
      parsed.targets.push(args[index + 1] || null);
      index += 1;
    } else if (arg === '--json') {
      parsed.json = true;
    } else if (arg === '--help' || arg === '-h') {
      parsed.help = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  return parsed;
}

function statusLabel(status) {
  if (status === 'ok') {
    return 'OK';
  }

  if (status === 'warning') {
    return 'WARNING';
  }

  if (status === 'error') {
    return 'ERROR';
  }

  return status.toUpperCase();
}

function checkReviewCli() {
  const { execFileSync } = require('child_process');
  const path = require('path');
  const configured = process.env.BUSDRIVER_REVIEW_CLI || 'auto';
  let resolved = 'unknown';
  let version = '';
  let status = 'ok';
  let message = '';

  try {
    const resolveScript = path.join(__dirname, 'lib', 'resolve-cli.sh');
    resolved = execFileSync('bash', ['-c', `source "${resolveScript}" && resolve_review_cli`], {
      encoding: 'utf8',
      env: { ...process.env },
      timeout: 5000,
    }).trim();
  } catch {
    resolved = 'error';
  }

  if (resolved === 'none') {
    status = 'warning';
    message = 'review gate disabled, commits pass without review';
  } else if (resolved === 'builtin') {
    message = 'commits will use built-in Claude review (less independent than external CLI)';
  } else if (resolved.startsWith('missing:')) {
    status = 'error';
    message = `CLI '${resolved.slice(8)}' not found - install it or set BUSDRIVER_REVIEW_CLI=auto`;
  } else if (resolved === 'error') {
    status = 'error';
    message = 'could not resolve review CLI';
  } else {
    try {
      version = execFileSync(resolved, ['--version'], {
        encoding: 'utf8',
        timeout: 5000,
      }).trim().split('\n')[0];
    } catch {
      version = 'unknown';
    }
    message = `commits will require ${resolved} review`;
  }

  return { configured, resolved, version, status, message };
}

function printHuman(report) {
  if (report.results.length === 0) {
    console.log('No ECC install-state files found for the current home/project context.');
    return;
  }

  console.log('Doctor report:\n');
  for (const result of report.results) {
    console.log(`- ${result.adapter.id}`);
    console.log(`  Status: ${statusLabel(result.status)}`);
    console.log(`  Install-state: ${result.installStatePath}`);

    if (result.issues.length === 0) {
      console.log('  Issues: none');
      continue;
    }

    for (const issue of result.issues) {
      console.log(`  - [${issue.severity}] ${issue.code}: ${issue.message}`);
    }
  }

  console.log(`\nSummary: checked=${report.summary.checkedCount}, ok=${report.summary.okCount}, warnings=${report.summary.warningCount}, errors=${report.summary.errorCount}`);

  const cli = checkReviewCli();
  console.log('\nReview Gate:');
  console.log(`  BUSDRIVER_REVIEW_CLI: ${cli.configured}`);
  const versionStr = cli.version ? ` (${cli.version})` : '';
  console.log(`  Resolved CLI: ${cli.resolved}${versionStr}`);
  console.log(`  Status: ${statusLabel(cli.status)} - ${cli.message}`);
}

function main() {
  try {
    const options = parseArgs(process.argv);
    if (options.help) {
      showHelp(0);
    }

    const report = buildDoctorReport({
      repoRoot: require('path').join(__dirname, '..'),
      homeDir: process.env.HOME,
      projectRoot: process.cwd(),
      targets: options.targets,
    });
    const hasIssues = report.summary.errorCount > 0 || report.summary.warningCount > 0;

    if (options.json) {
      console.log(JSON.stringify(report, null, 2));
    } else {
      printHuman(report);
    }

    process.exitCode = hasIssues ? 1 : 0;
  } catch (error) {
    console.error(`Error: ${error.message}`);
    process.exit(1);
  }
}

main();
