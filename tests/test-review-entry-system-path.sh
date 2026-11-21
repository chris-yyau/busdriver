#!/usr/bin/env bash
# tests/test-review-entry-system-path.sh — the review entry points resolve bare commands
# through the system directories first (#816).
#
# run-review-loop.sh has prepended /usr/bin:/bin since #576. init-review-loop.sh,
# init-design-review.sh and run-design-review-loop.sh did not, so a PATH entry ahead of the
# system directories (PATH is repo-injectable, #325 / ADR 0016) supplied every bare external
# command they ran. Each script is run with a logging `dirname` FIRST in PATH; all three call
# `dirname` to find their own directory, so the shim is consulted unless the system
# directories come before it.
#
# Not exercised here: the macOS-without-Command-Line-Tools arm (a failing /usr/bin/git or
# /usr/bin/python3 stub). It probes fixed absolute paths, so a test cannot fake it; on such a
# host the scripts keep the caller's PATH by design, and the test checks that instead.
#
# Usage: bash tests/test-review-entry-system-path.sh
# Exit: 0 if all pass, 1 if any fail.
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
mkdir -p "$SHIM" "$SANDBOX/repo"
# The log path is baked in: the BD803 environment rebuild may not pass variables through.
# shellcheck disable=SC2016  # $0 and $@ belong to the shim, not to this shell
printf '#!/bin/sh\nprintf "%%s\\n" "$0" >> "%s"\nexec /usr/bin/dirname "$@"\n' "$LOG" > "$SHIM/dirname"
chmod +x "$SHIM/dirname"

cd "$SANDBOX/repo" || exit 1
git init -q .
git config user.email t@t.com
git config user.name t

# Sanity: the shim really is what a plain PATH lookup finds.
found=$(PATH="$SHIM:$PATH" /bin/bash -c 'type -P dirname')
if [[ "$found" == "$SHIM/dirname" ]]; then
  ok "shim dirname is first in the test PATH"
else
  bad "shim dirname is not first in the test PATH; the assertions below would prove nothing"
fi

# The same probe the scripts run: where a /usr/bin git or python3 stub fails, they keep the
# caller's PATH (and warn), so there the test checks that fallback instead.
stub_broken=0
for t in git python3; do
  if [[ -x "/usr/bin/$t" ]] && ! /usr/bin/env -i PATH=/usr/bin:/bin "/usr/bin/$t" --version >/dev/null 2>&1; then
    stub_broken=1
  fi
done

# Each spec: <expected output fragment>|<script path under the repo> [args]. Every call ends
# early and harmlessly in the sandbox; the fragment is printed AFTER the script's first dirname
# call, so a script that aborted before reaching dirname cannot pass with an empty log.
for spec in \
  "Review loop initialized|skills/litmus/scripts/init-review-loop.sh 10" \
  "Usage:|skills/blueprint-review/scripts/init-design-review.sh" \
  "State file not found|skills/blueprint-review/scripts/run-design-review-loop.sh"; do
  want=${spec%%|*}
  read -r script args <<<"${spec#*|}"
  : > "$LOG"
  # shellcheck disable=SC2086  # args is a deliberate word list
  out=$(PATH="$SHIM:$PATH" /bin/bash -p "$REPO_ROOT/$script" $args 2>&1)
  if [[ "$stub_broken" -eq 1 ]]; then
    # The fallback: the caller's PATH is kept (the shim runs) and the run says so.
    if [[ "$out" == *"$want"* && -s "$LOG" && "$out" == *"WARNING: /usr/bin/git or /usr/bin/python3 fails"* ]]; then
      ok "$script: broken /usr/bin stub here, caller's PATH kept with a warning"
    else
      bad "$script: broken /usr/bin stub here, but the fallback did not keep the caller's PATH with a warning"
    fi
  elif [[ "$out" != *"$want"* ]]; then
    bad "$script: did not reach '$want'; the dirname check below would prove nothing"
  elif [[ -s "$LOG" ]]; then
    bad "$script: resolved bare dirname through a PATH entry ahead of /usr/bin"
  else
    ok "$script: bare dirname resolved from the system directories"
  fi
done

# macOS: the /usr/bin stubs honour DEVELOPER_DIR, which is as repo-injectable as PATH. Once the
# system directories go first the scripts drop it, so a bogus value cannot break (or redirect)
# the git they run. init-review-loop.sh is the entry point that runs git itself.
if [[ -x /usr/bin/xcrun && "$stub_broken" -eq 0 ]]; then
  rm -f .claude/litmus-state.md
  out=$(DEVELOPER_DIR=/nonexistent /bin/bash -p "$REPO_ROOT/skills/litmus/scripts/init-review-loop.sh" 10 2>&1)
  if [[ "$out" == *"Review loop initialized"* ]]; then
    ok "init-review-loop.sh: a bogus DEVELOPER_DIR does not reach the /usr/bin git stub"
  else
    bad "init-review-loop.sh: a bogus DEVELOPER_DIR broke the run: ${out:0:200}"
  fi
else
  echo "  SKIP  DEVELOPER_DIR case: no macOS developer-tools stubs that work here"
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
