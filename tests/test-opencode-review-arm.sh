#!/bin/bash
# test-opencode-review-arm.sh — guard tests for the opencode (Auditor) arm.
#
# The arm's read-only posture is NOT structural — it comes from a plugin-owned
# opencode config whose agent denies every tool except read/glob/grep. Two
# invariants must hold or the arm silently becomes a writing agent:
#
#   1. The shipped config actually denies by wildcard. Four probe rounds on
#      2026-07-20 showed every ENUMERATED denylist leaking (bash substitution,
#      `task` subagent delegation, then MCP tools + skills entirely outside the
#      built-in `tools` map). Only `"*": false` + a read allowlist held.
#   2. A missing/unreadable config FAILS CLOSED. opencode does not error on a
#      missing OPENCODE_CONFIG — it silently loads the user's default config,
#      restoring write/bash/task. So "cannot find config" must block dispatch.
#
# These are cheap static+unit checks; they deliberately do NOT call the network.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$REPO_ROOT/scripts/lib/opencode-review-config.json"
FAILURES=0

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILURES=$((FAILURES + 1)); }

echo "test-opencode-review-arm"

# ── 1. Shipped config denies by wildcard, not enumeration ──────────
if [[ ! -f "$CONFIG" ]]; then
  fail "config missing at $CONFIG"
else
  pass "config present"

  if python3 - "$CONFIG" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
tools = cfg["agent"]["busdriver-review"]["tools"]
# Wildcard deny is the invariant. An enumerated denylist is a REGRESSION even
# if it happens to list every tool known today — MCP/skill tools are not in it.
assert tools.get("*") is False, "missing wildcard deny '*': false"
allowed = {k for k, v in tools.items() if v is True}
assert allowed <= {"read", "glob", "grep"}, f"unexpected allowed tools: {allowed}"
for banned in ("write", "edit", "bash", "patch", "task", "webfetch"):
    assert tools.get(banned) is not True, f"{banned} explicitly allowed"
# Belt-and-suspenders: the tools wildcard already blocks these, but the explicit
# permission deny states intent and is a second layer if a future opencode
# release changes how the tools map interacts with permissions.
agent = cfg["agent"]["busdriver-review"]
for scope in (cfg, agent):
    perm = scope.get("permission", {})
    for k in ("bash", "edit", "webfetch", "external_directory"):
        assert perm.get(k) == "deny", f"permission.{k} not denied at a required scope"
PY
  then pass "wildcard deny + read-only allowlist"
  else fail "config does not deny-all / allows more than read,glob,grep"
  fi
fi

# ── 2. Config + binary are NOT repo-injectable via env ─────────────
# A reviewed fork's .claude/settings.json can inject env into the operator's
# session (#325 class). The security-critical config path and binary path must
# therefore NOT honor env overrides — asserted statically over both arms.
RC="$REPO_ROOT/scripts/lib/resolve-cli.sh"
DP="$REPO_ROOT/skills/dispatch-cli/scripts/dispatch.sh"
# shellcheck disable=SC2016  # single-quoted patterns are grep regexes, not shell expansions
# Match actual parameter EXPANSIONS (`${BUSDRIVER_OPENCODE_CONFIG` /
# `$BUSDRIVER_OPENCODE_BIN`), not comment mentions of the names.
if grep -qE '\$\{?BUSDRIVER_OPENCODE_CONFIG[:}]' "$RC" "$DP"; then
  fail "BUSDRIVER_OPENCODE_CONFIG expanded — config path is repo-injectable"
else
  pass "no BUSDRIVER_OPENCODE_CONFIG expansion (config not repo-injectable)"
fi
if grep -qE '\$\{?BUSDRIVER_OPENCODE_BIN[:}"]' "$RC" "$DP"; then
  fail "BUSDRIVER_OPENCODE_BIN expanded — binary path is repo-injectable"
else
  pass "no BUSDRIVER_OPENCODE_BIN expansion (binary not repo-injectable)"
fi

# ── 3. Fail-closed guards are present in the arm ───────────────────
# shellcheck disable=SC2016  # single-quoted patterns are grep regexes
# The config must be the plugin-owned file, resolved from _bd_lib_dir with an
# empty-lib-dir bail, and dispatch must block on a missing config file.
if grep -q 'if \[\[ -z "\$_bd_lib_dir" \]\]; then' "$RC" \
   && grep -q '_oc_cfg="\${_bd_lib_dir}/opencode-review-config.json"' "$RC" \
   && grep -q 'if \[\[ ! -f "\$_oc_cfg" \]\]; then' "$RC"; then
  pass "resolve-cli.sh: fail-closed on empty lib-dir and missing config"
else
  fail "resolve-cli.sh: missing fail-closed config guards"
fi

# ── 4. Both arms dispatch from a NEUTRAL cwd, not the reviewed tree ──
# This is the real boundary: a reviewed branch can redefine busdriver-review via
# .opencode/agent/*.md, opencode.json, opencode.jsonc, or a project plugin.
# Enumerating those is a losing game, so both arms must run somewhere the repo
# does not control. Assert structurally rather than by executing opencode.
# Extract the DISPATCH arm precisely — the file also has a one-line
# get_cli_install_hint `opencode)` branch, so a broad `opencode)`..`;;` range
# match would conflate them. Anchor on the actual invocation line instead: the
# arm must pass --dir <neutral>, isolate XDG_CONFIG_HOME, and mktemp -d it.
for _f in "$REPO_ROOT/scripts/lib/resolve-cli.sh" \
          "$REPO_ROOT/skills/dispatch-cli/scripts/dispatch.sh"; do
  # shellcheck disable=SC2016  # literal '$_oc_cwd' is the source text we grep FOR
  if grep -q '"\$_oc_bin" run --dir "\$_oc_cwd" --agent busdriver-review' "$_f" \
     && grep -q 'XDG_CONFIG_HOME="\$_oc_cwd"' "$_f" \
     && grep -q '_oc_cwd="\$(mktemp -d' "$_f" \
     && grep -q 'env -i ' "$_f" && grep -q 'cd "\$_oc_cwd"' "$_f" \
     && grep -q 'PATH="\$_oc_trust" command -v opencode' "$_f" \
     && grep -q '"\$_oc_bin" run --dir' "$_f"; then
    pass "$(basename "$_f"): opencode arm isolated (cwd + XDG + env -i + abs-bin)"
  else
    fail "$(basename "$_f"): opencode arm not fully isolated (cwd/XDG/env -i/abs-bin)"
  fi
done

# ── 5. No CWD fallback in the plugin-asset path resolution ─────────
# Under zsh BASH_SOURCE is empty; a `$0` fallback yields `dirname zsh` = "." and
# resolves plugin assets against the REVIEWED REPO, whose own
# opencode-review-config.json would then pass the -f check and become policy.
# shellcheck disable=SC2016  # literal '$0' is the pattern we grep FOR, not an expansion
if grep -qE '_bd_lib_dir=.*BASH_SOURCE\[0\]:-\$0' "$REPO_ROOT/scripts/lib/resolve-cli.sh"; then
  fail "_bd_lib_dir falls back to \$0 — resolves plugin assets against the reviewed repo under zsh"
else
  pass "_bd_lib_dir has no \$0/CWD fallback"
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "PASS (test-opencode-review-arm)"
  exit 0
fi
echo "FAIL: $FAILURES assertion(s) (test-opencode-review-arm)"
exit 1
