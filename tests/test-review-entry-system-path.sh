#!/usr/bin/env bash
# tests/test-review-entry-system-path.sh — the review entry points resolve bare commands
# through the system directories first, and drop DEVELOPER_DIR (#816).
#
# run-review-loop.sh has prepended /usr/bin:/bin since #576. init-review-loop.sh,
# init-design-review.sh and run-design-review-loop.sh did not, so a PATH entry ahead of the
# system directories (PATH is repo-injectable, #325 / ADR 0016) supplied every bare external
# command they ran. Each script is run with a logging `dirname` FIRST in PATH; all three call
# `dirname` to find their own directory, so the shim is consulted unless the system
# directories come before it.
#
# Usage: bash tests/test-review-entry-system-path.sh
# Exit: 0 if all pass, 1 if any fail.
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset BUSDRIVER_STATE_DIR  # the DEVELOPER_DIR case looks for the state file under .claude

PASS=0
FAIL=0
ok()  { printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
bad() { printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL + 1)); }

SANDBOX=$(mktemp -d) || { echo "FATAL: mktemp -d failed"; exit 1; }
if [[ -z "$SANDBOX" || ! -d "$SANDBOX" ]]; then
  echo "FATAL: sandbox path is not a directory: '$SANDBOX'"; exit 1
fi
trap 'if [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]]; then rm -rf "$SANDBOX"; fi' EXIT

SHIM="$SANDBOX/shim"
LOG="$SANDBOX/shim.log"
mkdir -p "$SHIM" "$SANDBOX/repo/sub"
# The shim finds its log next to its own directory, so no path is spliced into its source
# (and nothing depends on the BD803 environment rebuild passing a variable through).
# shellcheck disable=SC2016  # the shim's own $0 and $@
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$0" >> "${0%/*}/../shim.log"' 'exec /usr/bin/dirname "$@"' > "$SHIM/dirname"
chmod +x "$SHIM/dirname"

cd "$SANDBOX/repo" || exit 1
git init -q . || { echo "FATAL: git init failed in the sandbox"; exit 1; }

# Sanity: the shim is what a plain PATH lookup runs, and running it logs.
: > "$LOG"
got=$(PATH="$SHIM:$PATH" /bin/bash -c 'dirname /a/b')
if [[ "$got" == "/a" && -s "$LOG" ]]; then
  ok "shim dirname runs first in the test PATH and logs"
else
  bad "shim dirname did not run and log ('$got'); the assertions below would prove nothing"
fi

# Each spec: <exit status>|<expected output fragment>|<script path under the repo> [args].
# Every call ends early and harmlessly in the sandbox (the two blueprint calls on their usage
# and missing-state errors); the fragment is printed AFTER the script's first dirname call, so
# a script that aborted before reaching dirname cannot pass with an empty log.
for spec in \
  "0|Review loop initialized|skills/litmus/scripts/init-review-loop.sh 10" \
  "1|Usage:|skills/blueprint-review/scripts/init-design-review.sh" \
  "1|State file not found|skills/blueprint-review/scripts/run-design-review-loop.sh"; do
  want_rc=${spec%%|*}; rest=${spec#*|}
  want=${rest%%|*}
  read -r script args <<<"${rest#*|}"
  : > "$LOG"
  # shellcheck disable=SC2086  # args is a deliberate word list
  out=$(PATH="$SHIM:$PATH" /bin/bash -p "$REPO_ROOT/$script" $args 2>&1); rc=$?
  if [[ "$rc" -ne "$want_rc" || "$out" != *"$want"* ]]; then
    bad "$script: expected exit $want_rc and '$want', got exit $rc; the dirname check would prove nothing"
  elif [[ -s "$LOG" ]]; then
    bad "$script: resolved bare dirname through a PATH entry ahead of /usr/bin"
  else
    ok "$script: bare dirname resolved from the system directories"
  fi
done

# macOS: the /usr/bin stubs run the xcrun under DEVELOPER_DIR, which is as repo-injectable as
# PATH. A bogus value must not reach the git init-review-loop.sh runs: started from a
# subdirectory, it must still find the repository root (`git rev-parse --show-toplevel`) and
# write its state there, not in the subdirectory.
if [[ -x /usr/bin/xcrun ]] && /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/git --version >/dev/null 2>&1; then
  rm -rf .claude sub/.claude
  out=$(cd sub && DEVELOPER_DIR=/nonexistent /bin/bash -p "$REPO_ROOT/skills/litmus/scripts/init-review-loop.sh" 10 2>&1); rc=$?
  if [[ "$rc" -eq 0 && -f .claude/litmus-state.md && ! -e sub/.claude ]]; then
    ok "init-review-loop.sh: git still resolves the repo root under a bogus DEVELOPER_DIR"
  else
    bad "init-review-loop.sh: a bogus DEVELOPER_DIR broke git: ${out:0:200}"
  fi
else
  echo "  SKIP  DEVELOPER_DIR case: no working macOS developer-tools stubs here"
fi

# The three copies of the block must not drift apart.
extract() { sed -n '/^# BD816-SYSTEM-PATH-BEGIN$/,/^# BD816-SYSTEM-PATH-END$/p' "$REPO_ROOT/$1"; }
ref=$(extract skills/litmus/scripts/init-review-loop.sh)
if [[ -z "$ref" ]]; then
  bad "init-review-loop.sh carries no BD816-SYSTEM-PATH block"
else
  for f in skills/blueprint-review/scripts/init-design-review.sh skills/blueprint-review/scripts/run-design-review-loop.sh; do
    got=$(extract "$f")
    if [[ "$got" == "$ref" ]]; then
      ok "$f: BD816 block matches init-review-loop.sh"
    else
      bad "$f: BD816 block differs from init-review-loop.sh"
    fi
  done
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
