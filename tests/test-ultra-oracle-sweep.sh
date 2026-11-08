#!/bin/bash
# tests/test-ultra-oracle-sweep.sh — spec 2026-11-01 §11: nothing invokes the oracle CLI or reads a
# removed ultraOracle key; LAUNCH_WAIT_SECONDS survives only in the two amended ADRs. docs/plans and
# docs/specs are history and exempt.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0; pass() { echo "OK:   $1"; }; fail() { echo "FAIL: $1"; FAIL=1; }

PAT_CLI='(^|[;&|(`[:space:]]|\$\()oracle[[:space:]]+(-[-a-z]|serve|session|status)|is_cli_available[[:space:]]+oracle|command -v oracle([^A-Za-z0-9_]|$)|pgrep -fl oracle|oracle CLI not available'
PAT_KEY='ultraOracle\.(model|browserModelStrategy|chromeProfileDir|cookiePath|remoteHost|remoteToken|hideWindow|attachRunning|attachProfileDir)([^A-Za-z0-9_]|$)|ultra_oracle_(model|browser_model_strategy|chrome_profile|cookie_path|remote_host|remote_token|hide_window|attach_running|attach_profile_dir)([^A-Za-z0-9_]|$)'
# Word ends are spelled out: \b is a GNU extension the macOS regcomp behind git grep -E lacks.
sweep() { # <repo> <pattern> -> the offending lines, if any
  git -C "$1" grep -nE "$2" -- scripts skills commands hooks docs/examples README.md .claude/CLAUDE.md
}

# The guard can fire: a scratch repo holding one offender of each kind is caught.
S="$(mktemp -d)" || exit 1; trap 'rm -rf "$S"' EXIT
git -C "$S" init -q; mkdir -p "$S/scripts" "$S/docs/adr"
# shellcheck disable=SC2016   # the offenders are literal text
printf 'x=$(oracle --engine browser -p hi)\n' > "$S/scripts/a.sh"
# shellcheck disable=SC2016
printf 'v=$(jq -r .ultraOracle.remoteHost f)\n' > "$S/scripts/b.sh"
printf 'cap + 90 + LAUNCH_WAIT_SECONDS\n' > "$S/docs/adr/0099-x.md"
git -C "$S" add -A
if [ -n "$(sweep "$S" "$PAT_CLI")" ]; then pass "the CLI pattern catches an oracle invocation"; else fail "CLI pattern cannot fire"; fi
if [ -n "$(sweep "$S" "$PAT_KEY")" ]; then pass "the key pattern catches a removed-key read"; else fail "key pattern cannot fire"; fi

out="$(sweep "$DIR" "$PAT_CLI")"
if [ -z "$out" ]; then pass "nothing invokes the oracle CLI"; else fail "oracle CLI references:
$out"; fi
out="$(sweep "$DIR" "$PAT_KEY")"
if [ -z "$out" ]; then pass "nothing reads a removed ultraOracle key"; else fail "removed-key reads:
$out"; fi

want="$(printf '%s\n' docs/adr/0027-k3-mechanism-witness-ultimate-tier.md docs/adr/0030-blueprint-blocking-window.md)"
got="$(git -C "$DIR" grep -l 'LAUNCH_WAIT_SECONDS' -- docs/adr docs/examples | LC_ALL=C sort)"
if [ "$got" = "$want" ]; then pass "LAUNCH_WAIT_SECONDS survives only in ADR 0027 and ADR 0030"; else fail "LAUNCH_WAIT_SECONDS in: $got"; fi
if [ -n "$(git -C "$S" grep -l 'LAUNCH_WAIT_SECONDS' -- docs/adr)" ]; then pass "the doc check can fire"; else fail "doc check cannot fire"; fi

if [ "$FAIL" = 0 ]; then echo "PASS test-ultra-oracle-sweep"; else exit 1; fi
