#!/usr/bin/env bash
# tests/test-litmus-terminal-status.sh — fixture-driven, no production backdoor.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/litmus/scripts/run-review-loop.sh"

# Use a sandbox temp dir; copy the script + needed lib files
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

cd "$SANDBOX"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
mkdir -p .claude skills/litmus/scripts/lib scripts/lib
cp "$SCRIPT" skills/litmus/scripts/run-review-loop.sh
cp -r "$REPO_ROOT"/skills/litmus/scripts/lib/* skills/litmus/scripts/lib/ 2>/dev/null || true
cp -r "$REPO_ROOT"/scripts/lib/* scripts/lib/ 2>/dev/null || true

# Fixture 1: state.md with frontmatter but empty required field values
# → triggers the "missing iteration or max_iterations" setup_error exit.
#
# The state file must include the iteration: and max_iterations: keys with
# empty values rather than omitting them entirely, because run-review-loop.sh
# runs under set -euo pipefail and get_yaml_value's internal grep pipeline
# exits non-zero when a key is absent, causing the script to exit before
# reaching the write_terminal_status call.
#
# Stage a file so the script passes the "no staged changes" guard and
# reaches the YAML state-reading section.
echo "dummy" > file.txt
git add file.txt
printf -- '---\nactive: true\niteration: \nmax_iterations: \ncompletion_promise: null\nreview_mode: commit\n---\n' > .claude/litmus-state.md
bash skills/litmus/scripts/run-review-loop.sh 2>/dev/null || true
# shellcheck disable=SC2312  # $(cat ...) only invoked on FAIL branch for diagnostic
grep -q 'terminal_status:.*"setup_error"' .claude/litmus-state.md \
    || { echo "FAIL: setup_error not written ($(cat .claude/litmus-state.md))"; exit 1; }

# Fixture 2: stall / review_findings paths
# Implementing a full mock-CLI fixture for the stall path requires wiring up
# the script's iteration-history mechanism with a fake review CLI that returns
# identical FAIL output across iterations. This is deferred to a follow-up
# task alongside the broader litmus integration test infrastructure.
# Tracked: https://github.com/chris-yyau/busdriver/issues (from pr-grind PR #102)

echo "All available litmus terminal-status tests passed"
