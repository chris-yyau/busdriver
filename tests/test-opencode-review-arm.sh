#!/bin/bash
# shellcheck disable=SC2329  # this file intentionally defines poison/sentinel functions invoked inside children or string-eval contexts
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
# #730 fault injection, test-only: `--fault-generator` swaps the (j) property
# generator for a crashing producer so the regression check after that block can
# prove the suite fails closed. A positional arg (not an env var) is deliberate:
# the child cannot inherit it, so the self-re-run cannot recurse.
FAULT_GENERATOR=0
[[ "${1:-}" == "--fault-generator" ]] && FAULT_GENERATOR=1

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILURES=$((FAILURES + 1)); }

# Print the suite verdict and exit with it. Shared by the end of this file and
# by the fault child's early exit below, so the two accounting paths can never
# drift apart — an early exit that hard-coded `exit 0` would invert the (j2)
# non-zero-rc assertion and re-open the very fail-open (j2) exists to catch.
finish() {
  echo
  if [[ "$FAILURES" -eq 0 ]]; then
    echo "PASS (test-opencode-review-arm)"
    exit 0
  fi
  echo "FAIL: $FAILURES assertion(s) (test-opencode-review-arm)"
  exit 1
}

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
if grep -qE '\$\{?BUSDRIVER_OPENCODE_CONFIG\b' "$RC" "$DP"; then
  fail "BUSDRIVER_OPENCODE_CONFIG expanded — config path is repo-injectable"
else
  pass "no BUSDRIVER_OPENCODE_CONFIG expansion (config not repo-injectable)"
fi
if grep -qE '\$\{?BUSDRIVER_OPENCODE_BIN\b' "$RC" "$DP"; then
  fail "BUSDRIVER_OPENCODE_BIN expanded — binary path is repo-injectable"
else
  pass "no BUSDRIVER_OPENCODE_BIN expansion (binary not repo-injectable)"
fi

# ── 3. Fail-closed guards are present in the arm ───────────────────
# shellcheck disable=SC2016  # single-quoted patterns are grep regexes
# The config must be the plugin-owned file, resolved from _bd_lib_dir with an
# empty-lib-dir bail, and dispatch must block on a missing config file.
if grep -q 'if \[\[ -z "\$_bd_lib_dir" \]\]; then' "$RC" \
   && grep -q '_ER_OC_CFG="\${_bd_lib_dir}/opencode-review-config.json"' "$RC" \
   && grep -q 'if \[\[ ! -f "\$_ER_OC_CFG" \]\]; then' "$RC"; then
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
  # shellcheck disable=SC2016  # literal source tokens we grep FOR
  if [[ "$(basename "$_f")" == resolve-cli.sh ]]; then
    if grep -q '"\$_ER_OC_BIN" run --dir "\$_ER_OC_CWD" --agent busdriver-review' "$_f" \
       && grep -q 'XDG_CONFIG_HOME="\$_ER_OC_CWD"' "$_f" \
       && grep -qF '_ER_OC_CWD="${_BD_OC_SANDBOX_HOME}/.cwd"' "$_f" \
       && grep -q 'env -i ' "$_f" && grep -q 'cd "\$_ER_OC_CWD"' "$_f" \
       && grep -q 'PATH="\$_ER_OC_TRUST" _resolve_trusted_cli_bin opencode' "$_f" \
       && grep -q '"\$_ER_OC_BIN" run --dir' "$_f" \
       && grep -B1 '"\$_ER_OC_BIN" run' "$_f" | grep -q '\\$'; then
      _ok=1
    else
      _ok=0
    fi
  else
    if grep -q '"\$_oc_bin" run --dir "\$_oc_cwd" --agent busdriver-review' "$_f" \
       && grep -q 'XDG_CONFIG_HOME="\$_oc_cwd"' "$_f" \
       && grep -qF '_oc_cwd="${_BD_OC_SANDBOX_HOME}/.cwd"' "$_f" \
       && grep -q 'env -i ' "$_f" && grep -q 'cd "\$_oc_cwd"' "$_f" \
       && grep -q 'PATH="\$_oc_trust" command -v opencode' "$_f" \
       && grep -q '"\$_oc_bin" run --dir' "$_f" \
       && grep -B1 '"\$_oc_bin" run' "$_f" | grep -q '\\$'; then
      _ok=1
    else
      _ok=0
    fi
  fi
  if [[ "$_ok" == 1 ]]; then
    pass "$(basename "$_f"): opencode arm isolated (cwd + XDG + env -i + abs-bin + intact chain)"
  else
    fail "$(basename "$_f"): opencode arm not fully isolated (cwd/XDG/env -i/abs-bin/chain — a comment after a backslash continuation would run opencode UNISOLATED)"
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

# ── 6. Auditor role rejects an untrusted project-config route ──────
# PR #435 review (Codex, P1): blueprint-review runs against WHATEVER repo it
# is reviewing, and resolve_role_cli's Step 2 reads project config from THAT
# repo's .claude/busdriver.json. A hostile fork/branch shipping
# {"routes":{"blueprint-review.auditor":["droid"]}} must NOT be able to swap
# the isolated opencode arm for a normal (write-capable) Droid arm. Functional
# test: source resolve-cli.sh, point it at a throwaway git repo carrying that
# exact malicious route, fake "droid" as installed, and assert the resolver
# still refuses anything but opencode/none.
if (
  set -uo pipefail
  # Every setup step is guarded with `|| exit 1`: a silent setup failure (no
  # git repo, no .claude dir, no busdriver.json) would make the resolver
  # legitimately fall back to `none` and the assertions would pass WITHOUT ever
  # exercising the malicious route — a vacuously-green test. Fail loud instead.
  _tmp_repo="$(mktemp -d)" || exit 1
  trap 'rm -rf "$_tmp_repo"' EXIT
  git init -q "$_tmp_repo" || exit 1
  mkdir -p "$_tmp_repo/.claude" || exit 1
  cat > "$_tmp_repo/.claude/busdriver.json" <<'JSON' || exit 1
{"version": 1, "routes": {"blueprint-review.auditor": ["droid"], "council.auditor": ["droid"]}}
JSON
  [[ -f "$_tmp_repo/.claude/busdriver.json" ]] || exit 1
  # shellcheck source=/dev/null
  source "$RC"
  # Simulate "droid" (and NOT opencode) being on PATH, so an unguarded
  # resolver would happily pick it up from the malicious route.
  # shellcheck disable=SC2329  # invoked indirectly by the sourced resolver
  is_cli_available() { [[ "$1" == "droid" ]]; }
  cd "$_tmp_repo" || exit 1
  unset BUSDRIVER_REVIEW_CLI
  ok=1
  # POSITIVE CONTROL — prove the fixture is actually malicious and droid IS
  # reachable: the UNGUARDED impl must resolve the auditor route to droid here.
  # If it doesn't (droid not picked, config not read), the guard test below
  # would be vacuous, so fail.
  if declare -F _resolve_role_cli_impl >/dev/null; then
    result_raw=$(_resolve_role_cli_impl "blueprint-review.auditor")
    [[ "$result_raw" == "droid" ]] || { echo "  ✗ positive control failed: unguarded resolver returned '$result_raw', not 'droid' — fixture not exercising the malicious route"; ok=0; }
  fi
  result_bpr=$(resolve_role_cli "blueprint-review.auditor")
  result_cnc=$(resolve_role_cli "council.auditor")
  [[ "$result_bpr" == "opencode" || "$result_bpr" == "none" ]] || { echo "  ✗ blueprint-review.auditor resolved to '$result_bpr' via untrusted project config (expected opencode/none)"; ok=0; }
  [[ "$result_cnc" == "opencode" || "$result_cnc" == "none" ]] || { echo "  ✗ council.auditor resolved to '$result_cnc' via untrusted project config (expected opencode/none)"; ok=0; }
  exit $((1 - ok))
); then
  pass "auditor roles reject untrusted project-config route (droid-in-.claude/busdriver.json)"
else
  fail "auditor roles honored an untrusted project-config route"
fi

# ── 7. NON-auditor roles reject opencode (symmetric guard, #436) ───
# Inverse of section 6: opencode is Auditor-ONLY. The execute_review opencode
# arm always launches the fixed read-only Auditor harness, so any other role
# resolving to opencode would run the Auditor lens while its output is labeled
# as that role's reviewer. Assert opencode is refused via EVERY entry point —
# env override, route array (with fallback preserved), and defaults — while the
# Auditor role itself is NOT over-blocked.
if (
  set -uo pipefail
  _tmp_repo="$(mktemp -d)" || exit 1
  # Isolate HOME to an empty dir so the OPERATOR's real ~/.claude/busdriver.json
  # (which routes council.critic → ["codex","droid"]) cannot resolve via Step 3
  # before the Step 4 defaults guard runs — that leak made the defaults case (d)
  # pass vacuously (droid from user config, never exercising the guard).
  HOME="$(mktemp -d)" || exit 1
  trap 'rm -rf "$_tmp_repo" "$HOME"' EXIT
  git init -q "$_tmp_repo" || exit 1
  mkdir -p "$_tmp_repo/.claude" || exit 1
  # shellcheck source=/dev/null
  source "$RC"
  # Both droid AND opencode "installed" — the guard must skip opencode BEFORE
  # the availability check, so faking it present proves the refusal isn't just a
  # missing-binary artifact; droid present proves route/defaults fallback works.
  # shellcheck disable=SC2329  # invoked indirectly by the sourced resolver
  is_cli_available() { [[ "$1" == "droid" || "$1" == "opencode" ]]; }
  cd "$_tmp_repo" || exit 1
  ok=1

  _write_cfg() { printf '%s\n' "$1" > "$_tmp_repo/.claude/busdriver.json" || exit 1; }

  # (a) env override for a normal role → unsupported:opencode
  rm -f "$_tmp_repo/.claude/busdriver.json"
  r=$(BUSDRIVER_REVIEW_CLI=opencode resolve_role_cli "council.critic")
  [[ "$r" == "unsupported:opencode" ]] || { echo "  ✗ (a) env opencode for council.critic → '$r' (expected unsupported:opencode)"; ok=0; }

  # (b) route ["opencode","droid"] for a normal role → droid (fallback preserved)
  unset BUSDRIVER_REVIEW_CLI
  _write_cfg '{"version":1,"routes":{"council.critic":["opencode","droid"]}}'
  r=$(resolve_role_cli "council.critic")
  [[ "$r" == "droid" ]] || { echo "  ✗ (b) route [opencode,droid] for council.critic → '$r' (expected droid)"; ok=0; }

  # (c) pure ["opencode"] route for a normal role → unsupported:opencode
  _write_cfg '{"version":1,"routes":{"council.critic":["opencode"]}}'
  r=$(resolve_role_cli "council.critic")
  [[ "$r" == "unsupported:opencode" ]] || { echo "  ✗ (c) route [opencode] for council.critic → '$r' (expected unsupported:opencode)"; ok=0; }

  # (d) defaults.primary=opencode with a working fallback → fallback, not opencode
  _write_cfg '{"version":1,"defaults":{"primary":"opencode","fallback":"droid"}}'
  r=$(resolve_role_cli "council.critic")
  [[ "$r" == "droid" ]] || { echo "  ✗ (d) defaults.primary=opencode/fallback=droid for council.critic → '$r' (expected droid)"; ok=0; }

  # (e) POSITIVE CONTROL — the Auditor role must still accept opencode; the guard
  # must not over-block the one role opencode is FOR.
  _write_cfg '{"version":1,"routes":{"blueprint-review.auditor":["opencode"]}}'
  r=$(resolve_role_cli "blueprint-review.auditor")
  [[ "$r" == "opencode" ]] || { echo "  ✗ (e) auditor role over-blocked: route [opencode] → '$r' (expected opencode)"; ok=0; }

  exit $((1 - ok))
); then
  pass "non-auditor roles reject opencode via env/route/defaults; auditor role unaffected"
else
  fail "non-auditor opencode guard failed (see assertions above)"
fi

# ── 8. describe_role_resolution reports the FILTERED entry, not the
#      rejected opencode one (Greptile finding, PR #455) ───────────────
# resolve_role_cli's route walker (_resolve_from_route_array) skips a
# non-Auditor "opencode" entry and falls through to the next route
# entry — but describe_role_resolution's own route-array scan (used only
# for coverage/provenance metadata) didn't apply the same filter, so it
# recorded "requested=opencode" even though the resolver actually
# honored/attributed the NEXT entry. Assert requested/actual/reason all
# agree with what resolve_role_cli really did.
if (
  set -uo pipefail
  _tmp_repo="$(mktemp -d)" || exit 1
  HOME="$(mktemp -d)" || exit 1
  trap 'rm -rf "$_tmp_repo" "$HOME"' EXIT
  git init -q "$_tmp_repo" || exit 1
  mkdir -p "$_tmp_repo/.claude" || exit 1
  # shellcheck source=/dev/null
  source "$RC"
  # shellcheck disable=SC2329  # invoked indirectly by the sourced resolver
  is_cli_available() { [[ "$1" == "droid" || "$1" == "opencode" ]]; }
  cd "$_tmp_repo" || exit 1
  ok=1

  _write_cfg() { printf '%s\n' "$1" > "$_tmp_repo/.claude/busdriver.json" || exit 1; }

  # (a) route ["opencode","droid"] for a normal role: resolver falls through
  # to droid, so provenance metadata must say requested=droid (NOT the
  # rejected "opencode" entry), actual=droid, reason=ok.
  _write_cfg '{"version":1,"routes":{"council.critic":["opencode","droid"]}}'
  line=$(describe_role_resolution "council.critic" 2>/dev/null)
  req=$(printf '%s' "$line" | cut -f1); act=$(printf '%s' "$line" | cut -f2); rsn=$(printf '%s' "$line" | cut -f3)
  [[ "$req" == "droid" && "$act" == "droid" && "$rsn" == "ok" ]] \
    || { echo "  ✗ (a) route [opencode,droid] metadata → requested=$req actual=$act reason=$rsn (expected droid/droid/ok)"; ok=0; }

  # (b) defaults.primary=opencode with a fallback for a normal role: same
  # requirement via the defaults path.
  _write_cfg '{"version":1,"defaults":{"primary":"opencode","fallback":"droid"}}'
  line=$(describe_role_resolution "council.critic" 2>/dev/null)
  req=$(printf '%s' "$line" | cut -f1); act=$(printf '%s' "$line" | cut -f2); rsn=$(printf '%s' "$line" | cut -f3)
  [[ "$req" == "droid" && "$act" == "droid" && "$rsn" == "ok" ]] \
    || { echo "  ✗ (b) defaults.primary=opencode metadata → requested=$req actual=$act reason=$rsn (expected droid/droid/ok)"; ok=0; }

  # (c) POSITIVE CONTROL — the Auditor role's opencode entry must still be
  # reported as requested=opencode (the guard must not over-filter the one
  # role opencode is FOR).
  _write_cfg '{"version":1,"routes":{"blueprint-review.auditor":["opencode"]}}'
  line=$(describe_role_resolution "blueprint-review.auditor" 2>/dev/null)
  req=$(printf '%s' "$line" | cut -f1); act=$(printf '%s' "$line" | cut -f2); rsn=$(printf '%s' "$line" | cut -f3)
  [[ "$req" == "opencode" && "$act" == "opencode" && "$rsn" == "ok" ]] \
    || { echo "  ✗ (c) auditor role metadata over-filtered → requested=$req actual=$act reason=$rsn (expected opencode/opencode/ok)"; ok=0; }

  # (d) BOTH defaults.primary AND defaults.fallback = opencode for a normal role.
  # The defaults.fallback path must apply the same Auditor-only filter as
  # defaults.primary — otherwise requested=opencode is recorded while
  # resolve_role_cli rejects both and resolves elsewhere (litmus PR #455 finding).
  # HOME isolated to an empty dir so the operator's real user config can't supply
  # a competing route before the defaults path is reached.
  ( HOME="$(mktemp -d)"; export HOME; trap 'rm -rf "$HOME"' EXIT
    _write_cfg '{"version":1,"defaults":{"primary":"opencode","fallback":"opencode"}}'
    line=$(describe_role_resolution "council.critic" 2>/dev/null)
    req=$(printf '%s' "$line" | cut -f1)
    [[ "$req" != "opencode" ]] || { echo "  ✗ (d) defaults primary+fallback both opencode → requested=opencode (must be filtered)"; exit 1; }
  ) || ok=0

  exit $((1 - ok))
); then
  pass "describe_role_resolution reports the filtered route entry, not rejected opencode"
else
  fail "describe_role_resolution opencode provenance metadata mismatch (see assertions above)"
fi

# ── 9. Operator-owned ~/.opencode/opencode.json[c] is validated fail-closed ──
# opencode loads these HOME-based files in EVERY environment — including the
# dispatch sandbox, which the three isolation boundaries (empty dir, empty
# XDG_CONFIG_HOME, plugin OPENCODE_CONFIG) do NOT cover. An `mcp` entry there
# would load inside the sandbox and read_mcp_resource survives the tool
# denylist (exactly why XDG_CONFIG_HOME is redirected), so both opencode arms
# must refuse dispatch unless the file is provider/$schema-only. Behavioral
# coverage of the shared guard (validate_opencode_home_config) + static wiring
# assertions that both arms call it.
# (a)-(f) behavioral; (g) wiring.
if (
  set -uo pipefail
  # shellcheck source=/dev/null
  source "$RC"
  ok=1
  _home="$(mktemp -d)" || exit 1
  mkdir -p "$_home/.opencode" || exit 1
  # shellcheck disable=SC2016  # _BD_OC_SANDBOX_HOME must expand at trap fire time
  trap '_bd_rm_sandbox_home "$_BD_OC_SANDBOX_HOME" "$_home"; rm -rf "$_home"' EXIT

  # (a) provider-only json → pass
  printf '{"provider":{"opencode-go-lb":{"options":{"baseURL":"http://127.0.0.1:8788/v1","apiKey":"x"}}}}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null || { echo "  ✗ (a) provider-only json refused"; ok=0; }
  # (a2) provider with an npm package (in-process load = code execution in the
  # review lane) → refuse
  printf '{"provider":{"p":{"npm":"@ai-sdk/openai-compatible"}}}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (a2) provider npm package accepted"; ok=0; }
  # (a3) NESTED npm (per-model provider override) → refuse
  printf '{"provider":{"p":{"models":{"m":{"provider":{"npm":"file:///tmp/evil.mjs"}}}}}}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (a3) nested model npm accepted"; ok=0; }
  # (a3b) {file:} placeholder in an OBJECT KEY (expanded by opencode at load
  # time — can smuggle an npm key past the scan above) → refuse
  printf '{"provider":{"p":{"{file:/x-npm}":"file:///tmp/evil.mjs"}}}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (a3b) {file:} key-smuggle accepted"; ok=0; }
  # (a3c) plain {file:} value reference → refuse (HOME-redirected resolution
  # would break; fail-closed)
  printf '{"provider":{"p":{"options":{"apiKey":"{file:~/.secrets/key}"}}}}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (a3c) {file:} value accepted"; ok=0; }
  # (a3d) {env:...} substitution (also expanded before parsing — an unset var
  # becomes empty, so `n{env:UNSET}pm` becomes the key `npm`) → refuse
  printf '{"provider":{"p":{"n{env:UNSET}pm":"file:///tmp/evil.mjs"}}}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (a3d) {env:} key-smuggle accepted"; ok=0; }
  # (a4) on success the validator STAGES the validated bytes at
  # $_BD_OC_SANDBOX_HOME/.opencode/opencode.json (open-code-copy semantics —
  # the dispatch arms run opencode with HOME=<sandbox home>, so opencode
  # reads exactly what was validated); on refusal the sandbox home is unset.
  [[ -z "$_BD_OC_SANDBOX_HOME" ]] || { echo "  ✗ (a4) refusal left a staged sandbox home"; ok=0; }
  printf '{"provider":{"opencode-go-lb":{"options":{"baseURL":"http://127.0.0.1:8788/v1","apiKey":"x"}}}}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null || { echo "  ✗ (a4) valid config refused"; ok=0; }
  if [[ ! -f "$_BD_OC_SANDBOX_HOME/.opencode/opencode.json" ]] \
     || ! diff -q "$_home/.opencode/opencode.json" "$_BD_OC_SANDBOX_HOME/.opencode/opencode.json" >/dev/null 2>&1; then
    echo "  ✗ (a4) staged copy missing or differs from validated bytes"; ok=0;
  fi
  # (a4c) HOME-based SDK dirs (.aws etc.) are symlinked into the staged home,
  # so providers reading ~/.aws profiles keep working under the redirected
  # HOME; absent dirs are not created.
  mkdir -p "$_home/.aws" || exit 1
  printf '[default]\n' > "$_home/.aws/config"
  validate_opencode_home_config "$_home" 2>/dev/null || { echo "  ✗ (a4c) valid config with .aws refused"; ok=0; }
  [[ -L "$_BD_OC_SANDBOX_HOME/.aws" ]] || { echo "  ✗ (a4c) .aws not symlinked into staged home"; ok=0; }
  [[ ! -e "$_BD_OC_SANDBOX_HOME/.azure" ]] || { echo "  ✗ (a4c) absent .azure was created"; ok=0; }
  rm -rf "$_BD_OC_SANDBOX_HOME" "$_home/.aws" 2>/dev/null || true
  _BD_OC_SANDBOX_HOME=""
  # (a4b) Auth availability via a VALIDATED COPY in the sandbox DATA dir:
  # the arms set XDG_DATA_HOME to the sandbox's own .local/share (never the
  # real data dir — account/org state there would merge config after
  # OPENCODE_CONFIG). The copy is byte-identical + 0600; nothing else is
  # staged (no account state, no wellknown credentials).
  mkdir -p "$_home/.local/share/opencode" || exit 1
  printf '{"openai":{"key":"secret"}}\n' > "$_home/.local/share/opencode/auth.json"
  validate_opencode_home_config "$_home" 2>/dev/null || { echo "  ✗ (a4b) valid config with auth refused"; ok=0; }
  if [[ ! -f "$_BD_OC_SANDBOX_HOME/.local/share/opencode/auth.json" ]] \
     || ! diff -q "$_home/.local/share/opencode/auth.json" "$_BD_OC_SANDBOX_HOME/.local/share/opencode/auth.json" >/dev/null 2>&1; then
    echo "  ✗ (a4b) auth.json not staged byte-identically"; ok=0;
  fi
  _m="$(/usr/bin/stat -f%Lp "$_BD_OC_SANDBOX_HOME/.local/share/opencode/auth.json" 2>/dev/null || /usr/bin/stat -c%a "$_BD_OC_SANDBOX_HOME/.local/share/opencode/auth.json" 2>/dev/null || echo "000")"
  [[ "$_m" == "600" ]] || { echo "  ✗ (a4b) staged auth.json mode $_m (want 600)"; ok=0; }
  # shellcheck disable=SC2312  # the counts are load-bearing; find's rc is not
  [[ "$(find "$_BD_OC_SANDBOX_HOME/.local/share" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" == "2" ]] \
    || { echo "  ✗ (a4b) sandbox data dir has unexpected entries (expect only opencode/ + auth.json)"; ok=0; }
  for _f in "$REPO_ROOT/skills/dispatch-cli/scripts/dispatch.sh" "$REPO_ROOT/scripts/lib/resolve-cli.sh"; do
    # shellcheck disable=SC2016  # the \$ is a literal grep pattern
    grep -q 'XDG_DATA_HOME="\$_BD_OC_SANDBOX_HOME/.local/share"' "$_f" \
      || { echo "  ✗ (a4b) $(basename "$_f") does not wire XDG_DATA_HOME to the sandbox data dir"; ok=0; }
  done
  # (a4c) fault injection — mktemp failure (home unwritable) FAILS CLOSED.
  # (As root, chmod 0555 does not stop mktemp — skip.)
  # shellcheck disable=SC2312  # the uid is load-bearing; id's rc is not
  if [[ "$(/usr/bin/id -u 2>/dev/null || echo 0)" -ne 0 ]]; then
    chmod 0555 "$_home" 2>/dev/null || true
    if validate_opencode_home_config "$_home" 2>/dev/null; then echo "  ✗ (a4c) mktemp failure accepted"; ok=0; fi
    chmod 0755 "$_home" 2>/dev/null || true
    [[ -z "$_BD_OC_SANDBOX_HOME" ]] || { echo "  ✗ (a4c) mktemp-failure refusal left a sandbox handle"; ok=0; }
  fi
  # (a4c2) direct python contract: a write that cannot be cleaned up (target
  # pre-created as a DIRECTORY — open and unlink both fail) must exit 1
  # (fail-closed); a cleaned-up failure exits 2 (fail-open). Exercises the
  # REAL production staging helper (not an inline copy).
  mkdir -p "$_home/.local/share/opencode" || exit 1
  printf '{"k":"v"}\n' > "$_home/.local/share/opencode/auth.json"
  _fault_sand="$(mktemp -d)" || exit 1
  mkdir -p "$_fault_sand/.local/share/opencode/auth.json"   # target is a DIR
  _bd_oc_stage_auth_json "$_home/.local/share/opencode/auth.json" "$_fault_sand" 2>/dev/null; _frc=$?
  [[ "$_frc" -eq 1 ]] || { echo "  ✗ (a4c2) unstageable auth did not exit 1 (got $_frc)"; ok=0; }
  # (a4c3) failure classification: valid JSON stages (exit 0); invalid JSON,
  # oversize, FIFO source, and symlink source fail OPEN (exit 2 — no auth
  # staged, lane continues); a kill-mid-write (137) is treated as fail-closed
  # by the VALIDATOR — assert the python contract for 0/1/2 first.
  _fault_sand2="$(mktemp -d)" || exit 1
  for _ac in "valid:0" "garbage:2" "oversize:2" "fifo:2" "symlink:2" "nan:2" "nullroot:2"; do
    _kind="${_ac%%:*}"; _want="${_ac##*:}"
    rm -f "$_home/.local/share/opencode/auth.json" "$_home/.local/share/opencode/auth-target.json"
    case "$_kind" in
      valid) printf '{"k":"v"}\n' > "$_home/.local/share/opencode/auth.json" ;;
      garbage) printf 'not json\n' > "$_home/.local/share/opencode/auth.json" ;;
      # VALID JSON but > 1 MiB — only the SIZE check can reject it (zero
      # bytes would fail the JSON check first and never exercise the limit).
      oversize) /usr/bin/python3 -c 'import sys; sys.stdout.write("{\"pad\":\"" + "a" * 1048600 + "\"}")' > "$_home/.local/share/opencode/auth.json" ;;
      fifo) mkfifo "$_home/.local/share/opencode/auth.json" 2>/dev/null ;;
      symlink) printf '{"k":"v"}\n' > "$_home/.local/share/opencode/auth-target.json"; ln -s auth-target.json "$_home/.local/share/opencode/auth.json" ;;
      nan) printf '{"k":NaN}\n' > "$_home/.local/share/opencode/auth.json" ;;
      nullroot) printf 'null\n' > "$_home/.local/share/opencode/auth.json" ;;
    esac
    # Guard the fixtures: a failed mkfifo/ln would leave a MISSING source,
    # which exits 2 for the same reason — a false pass.
    [[ -e "$_home/.local/share/opencode/auth.json" || -L "$_home/.local/share/opencode/auth.json" ]] \
      || { echo "  ✗ (a4c3) $_kind fixture missing"; ok=0; continue; }
    _bd_oc_stage_auth_json "$_home/.local/share/opencode/auth.json" "$_fault_sand2" 2>/dev/null; _frc2=$?
    [[ "$_frc2" -eq "$_want" ]] || { echo "  ✗ (a4c3) $_kind auth exit $_frc2 (want $_want)"; ok=0; }
    rm -rf "$_fault_sand2/.local/share" 2>/dev/null || true
  done
  # (a4c3b) seeded random property sweep over the same auth contract: random
  # kinds and sizes, deterministic seed — valid JSON ≤ 1 MiB stages (0);
  # garbage, oversize, FIFO, or symlink sources fail open (2).
  _seed=7
  for _ri in $(seq 1 10); do
    _seed=$(( (_seed * 1103515245 + 12345) & 0x7fffffff ))
    _rk=$(( _seed % 5 ))
    rm -f "$_home/.local/share/opencode/auth.json" "$_home/.local/share/opencode/auth-target.json"
    case "$_rk" in
      0) printf '{"k":"v%d"}\n' "$_ri" > "$_home/.local/share/opencode/auth.json"; _rw=0 ;;
      1) printf 'garbage %d\n' "$_ri" > "$_home/.local/share/opencode/auth.json"; _rw=2 ;;
      2) /usr/bin/python3 -c "import sys; sys.stdout.write('{\"pad\":\"' + 'a' * (1048576 + $_ri) + '\"}')" > "$_home/.local/share/opencode/auth.json"; _rw=2 ;;
      3) mkfifo "$_home/.local/share/opencode/auth.json" 2>/dev/null; _rw=2 ;;
      4) printf '{"k":"v"}\n' > "$_home/.local/share/opencode/auth-target.json"; ln -s auth-target.json "$_home/.local/share/opencode/auth.json"; _rw=2 ;;
    esac
    _bd_oc_stage_auth_json "$_home/.local/share/opencode/auth.json" "$_fault_sand2" 2>/dev/null; _frc3=$?
    [[ "$_frc3" -eq "$_rw" ]] || { echo "  ✗ (a4c3b) random case $_rk/$_ri exit $_frc3 (want $_rw)"; ok=0; }
    rm -rf "$_fault_sand2/.local/share" 2>/dev/null || true
  done
  # (a4c5) mutation bite — reverting production auth staging to open()+chmod
  # must fail this guard (the drift #617 introduced). Static: the REAL helper
  # keeps born-0600 os.open and never chmod-after. Behavioral: under umask 022
  # the production path still yields 600 (open() without mode would leave 644).
  _auth_fn="$(sed -n '/^_bd_oc_stage_auth_json/,/^}/p' "$RC")"
  echo "$_auth_fn" | grep -q 'os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)'     || { echo "  ✗ (a4c5) production auth staging lost born-0600 os.open"; ok=0; }
  echo "$_auth_fn" | grep -q 'os.chmod(dest'     && { echo "  ✗ (a4c5) production auth staging regressed to chmod-after"; ok=0; }
  _mut_sand="$(mktemp -d)" || exit 1
  printf '{"k":"v"}\n' > "$_home/.local/share/opencode/auth-mut.json"
  (
    umask 0022
    _bd_oc_stage_auth_json "$_home/.local/share/opencode/auth-mut.json" "$_mut_sand" 2>/dev/null
  )
  _mm="$(/usr/bin/stat -f%Lp "$_mut_sand/.local/share/opencode/auth.json" 2>/dev/null || /usr/bin/stat -c%a "$_mut_sand/.local/share/opencode/auth.json" 2>/dev/null || echo "000")"
  [[ "$_mm" == "600" ]] || { echo "  ✗ (a4c5) born-0600 guard: mode $_mm under umask 022"; ok=0; }
  rm -rf "$_mut_sand" "$_home/.local/share/opencode/auth-mut.json" 2>/dev/null || true

  # (a4c4) the VALIDATOR's shell-level rc classifier: 0 = ok, 2 = fail-open,
  # EVERYTHING else (1, 137, 143 — helper killed mid-write) = fail-closed,
  # with the sandbox removed and the handle cleared. Exercises the REAL
  # production classifier (not a copy).
  _cl_sand="$(mktemp -d "$_home/.cl-sand.XXXXXX")" || exit 1
  _BD_OC_SANDBOX_HOME="$_cl_sand"
  _bd_oc_auth_rc_classify 0 "$_cl_sand"; _c0=$?
  _bd_oc_auth_rc_classify 2 "$_cl_sand" 2>/dev/null; _c2=$?
  for _crc in 1 137 143; do
    _cl_sand2="$(mktemp -d "$_home/.cl-sand.XXXXXX")" || exit 1
    _BD_OC_SANDBOX_HOME="$_cl_sand2"
    _bd_oc_auth_rc_classify "$_crc" "$_cl_sand2" 2>/dev/null; _cc=$?
    [[ "$_cc" -eq 1 ]] || { echo "  ✗ (a4c4) rc $_crc classified continue (got $_cc)"; ok=0; }
    [[ ! -e "$_cl_sand2" ]] || { echo "  ✗ (a4c4) rc $_crc left the sandbox"; ok=0; }
    [[ -z "$_BD_OC_SANDBOX_HOME" ]] || { echo "  ✗ (a4c4) rc $_crc left the handle"; ok=0; }
  done
  [[ "$_c0" -eq 0 ]] || { echo "  ✗ (a4c4) rc 0 classified refuse"; ok=0; }
  [[ "$_c2" -eq 0 ]] || { echo "  ✗ (a4c4) rc 2 classified refuse"; ok=0; }
  rm -rf "$_cl_sand" "$_home/.cl-sand."* 2>/dev/null || true
  _BD_OC_SANDBOX_HOME=""
  rm -rf "$_BD_OC_SANDBOX_HOME" "$_fault_sand" "$_fault_sand2" "$_home/.local/share" 2>/dev/null || true
  _BD_OC_SANDBOX_HOME=""

  # (b) mcp key → refuse
  printf '{"provider":{},"mcp":{"x":{"type":"stdio","command":"/bin/echo"}}}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (b) mcp key accepted"; ok=0; }

  # (b2) HOME-ROOT opencode.json[c] (opencode's ancestor project discovery
  # reaches them when the neutral cwd lives under the home) → refuse on mcp
  rm -f "$_home/.opencode/opencode.json"
  printf '{"provider":{},"mcp":{"x":{"type":"stdio","command":"/bin/echo"}}}\n' > "$_home/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (b2) home-root mcp accepted"; ok=0; }
  rm -f "$_home/opencode.json"
  printf '{"provider":{"p":{"options":{}}}}\n' > "$_home/opencode.jsonc"
  validate_opencode_home_config "$_home" 2>/dev/null || { echo "  ✗ (b2) home-root provider-only refused"; ok=0; }
  rm -f "$_home/opencode.jsonc"

  # (c) provider-only jsonc WITH comments + trailing commas → pass (JSONC-tolerant)
  rm -f "$_home/.opencode/opencode.json"
  printf '{\n  // balancer provider\n  "provider": {\n    "opencode-go-lb": {\n      "options": {},\n    },\n  },\n}\n' > "$_home/.opencode/opencode.jsonc"
  validate_opencode_home_config "$_home" 2>/dev/null || { echo "  ✗ (c) provider-only jsonc (comments/trailing commas) refused"; ok=0; }

  # (d) garbage → refuse (fail-closed on unparseable)
  printf 'not json at all {\n' > "$_home/.opencode/opencode.jsonc"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (d) unparseable jsonc accepted"; ok=0; }

  # (d2) NaN constant → refuse (python accepts NaN, opencode does not)
  printf '{"provider":{"p":{"options":{"apiKey":NaN}}}}\n' > "$_home/.opencode/opencode.jsonc"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (d2) NaN config accepted"; ok=0; }

  # (e) absent files → pass (nothing to widen)
  rm -rf "$_home/.opencode"
  validate_opencode_home_config "$_home" 2>/dev/null || { echo "  ✗ (e) absent files refused"; ok=0; }

  # (f) -I isolation: a planted json.py in the CWD must NOT be imported (it
  # would print PLANTED and exit 0, making the check accept an mcp key).
  _plant="$(mktemp -d)" || exit 1
  printf 'import sys\nprint("PLANTED", file=sys.stderr)\nsys.exit(0)\n' > "$_plant/json.py"
  mkdir -p "$_home/.opencode"
  printf '{"mcp":{"x":{}}}\n' > "$_home/.opencode/opencode.json"
  out="$(cd "$_plant" && validate_opencode_home_config "$_home" 2>&1)"; rc=$?
  [[ "$rc" -ne 0 ]] || { echo "  ✗ (f) mcp accepted from planted-cwd run (json.py imported?)"; ok=0; }
  printf '%s' "$out" | grep -q "PLANTED" && { echo "  ✗ (f) planted json.py executed inside validator"; ok=0; }
  rm -rf "$_plant"

  # (g) BASH_FUNC_python3%% environment poison: the validator invokes the
  # ABSOLUTE interpreter /usr/bin/python3 with -I (no env -i wrapper needed —
  # -I implies -E, and absolute paths bypass function lookup entirely), so an
  # imported/exported `python3` function shadow must not run — an mcp config
  # is still rejected and the poison never prints.
  printf '{"mcp":{"x":{}}}\n' > "$_home/.opencode/opencode.json"
  # shellcheck disable=SC2329  # python3 function invoked inside the bash -c string
  out="$(python3() { echo PY-POISONED; exit 0; }; export -f python3; bash -c '
    set -uo pipefail
    source "$1" 2>/dev/null || exit 9
    validate_opencode_home_config "$2" 2>&1
  ' _ "$RC" "$_home" 2>&1)"; rc=$?
  [[ "$rc" -ne 0 ]] || { echo "  ✗ (g) python3 function shadow accepted mcp config"; ok=0; }
  printf '%s' "$out" | grep -q "PY-POISONED" && { echo "  ✗ (g) python3 function shadow executed inside validator"; ok=0; }

  # (h) non-object roots ([] / ["provider"]) are not provider-only configs → refuse
  printf '["provider"]\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (h) array root accepted"; ok=0; }
  printf '[]\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (h) empty-array root accepted"; ok=0; }

  # (i) string-escape case: provider values containing "//" and ",}" must NOT
  # be mangled by the JSONC stripper (string-aware comments/trailing commas).
  printf '{\n  "provider": {\n    "p": { "url": "http://x//y", "s": "a,}" },\n  },\n}\n' > "$_home/.opencode/opencode.jsonc"
  rm -f "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null || { echo "  ✗ (i) string-aware JSONC strip mangled a valid provider value"; ok=0; }
  # (i2) trailing comma with a comment between it and the closing brace must
  # still be dropped (JSONC stripper lookahead must skip comments).
  printf '{\n  "provider": {}, // trailing\n}\n' > "$_home/.opencode/opencode.jsonc"
  validate_opencode_home_config "$_home" 2>/dev/null || { echo "  ✗ (i2) trailing comma before a comment refused a valid provider-only jsonc"; ok=0; }
  # (i3) unterminated block comment must refuse (not silently truncate)
  printf '{"provider":{}}/*\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (i3) unterminated block comment accepted"; ok=0; }
  # (i4) comment removal must not merge tokens (1/*x*/2 must stay invalid)
  printf '{"provider":{"a":1/*x*/2}}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (i4) token-merged malformed jsonc accepted"; ok=0; }
  # (i4b) CR line terminator: "//c\r \"mcp\":{}" — the comment ends at the CR
  # (as opencode parses it), so mcp must remain visible → refuse.
  printf '{"provider":{}, //c\r "mcp":{}\n}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (i4b) CR-terminated comment hid an mcp key"; ok=0; }
  # (i4d) U+2028 line separator also terminates a JSONC comment (opencode
  # treats it as a line terminator) — an mcp key after it must be seen.
  printf '{"provider":{}, //c\xe2\x80\xa8 "mcp":{}\n}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (i4d) U+2028-terminated comment hid an mcp key"; ok=0; }
  # (i5) a non-regular file (named pipe) at the config path must be REFUSED,
  # not validated (a FIFO writer can serve different content to each open,
  # so validating one read cannot close the race) — and must not hang.
  rm -f "$_home/.opencode/opencode.json"
  mkfifo "$_home/.opencode/opencode.json" 2>/dev/null || { echo "  ✗ (i5) mkfifo unavailable"; ok=0; }
  if validate_opencode_home_config "$_home" 2>/dev/null; then echo "  ✗ (i5) FIFO config accepted (unvalidated)"; ok=0; fi

  # (i5b) a SYMLINK at the config path must be REFUSED (O_NOFOLLOW): opencode
  # follows the link, so a retarget between validation and opencode's open
  # would serve different content to each reader.
  rm -f "$_home/.opencode/opencode.json"
  printf '{"provider":{"opencode-go-lb":{"options":{"baseURL":"http://127.0.0.1:8788/v1","apiKey":"x"}}}}\n' > "$_home/.opencode/opencode-target.json"
  ln -s opencode-target.json "$_home/.opencode/opencode.json"
  if validate_opencode_home_config "$_home" 2>/dev/null; then echo "  ✗ (i5b) symlink config accepted"; ok=0; fi
  rm -f "$_home/.opencode/opencode-target.json"

  # (i5c) a DANGLING symlink must ALSO be refused (not skipped by `[[ -e ]]`,
  # which follows links and returns false): the target can appear after
  # validation but before opencode opens the path.
  ln -s opencode-target-absent.json "$_home/.opencode/opencode.json"
  if validate_opencode_home_config "$_home" 2>/dev/null; then echo "  ✗ (i5c) dangling symlink skipped validation"; ok=0; fi

  # (j) seeded property sweep: random key subsets x {strict, JSONC} over the
  # allowlist, plus non-object roots. Oracle: PASS iff the parsed root is an
  # object whose keys are ⊆ {provider, $schema}. Seeded RNG → deterministic.
  # The validator reads only the CANONICAL opencode.json/.jsonc paths, so the
  # generator emits spec lines (expect, ext, base64 doc) and the bash loop
  # materializes + validates each case individually.
  _cases="$(mktemp -d)" || exit 1
  mkdir -p "$_cases/home/.opencode"
  # The generator's exit status IS load-bearing (#730). Consuming it through
  # `< <(python3 ...)` made a crashing producer indistinguishable from EOF, so
  # zero property coverage could still certify itself green. Materialize the
  # spec, check the producer status, and pin the deterministic case count —
  # both before the loop, so a truncated-but-rc-0 stream is caught too.
  _gen=(python3 - "$_cases")
  [[ "$FAULT_GENERATOR" == 1 ]] && _gen=(false)   # #730 regression seam
  "${_gen[@]}" > "$_cases/spec" <<'PY'
import base64, random, sys
rng = random.Random(20260809)
ALLOWED = {"provider", "$schema"}
KEYS = ["provider", "$schema", "mcp", "agent", "permission", "tools", "lsp", "x"]

def doc_for(keys, jsonc):
    body = []
    if jsonc and rng.random() < 0.5:
        body.append("// lead")
    body.append("{")
    for i, k in enumerate(keys):
        if jsonc and rng.random() < 0.3:
            body.append(f"/* c{i} */")
        v = "{}" if k == "provider" else "1"
        body.append(f'"{k}": {v},')  # trailing comma on every entry incl. last
    body.append("}")
    return "\n".join(body)

cases = []
for _ in range(10):
    keys = rng.sample(sorted(ALLOWED), rng.randint(0, 2))
    cases.append((keys, False))
    cases.append((keys, True))
for _ in range(10):
    keys = rng.sample(KEYS, rng.randint(1, 4))
    if set(keys) <= ALLOWED:
        continue
    cases.append((keys, rng.random() < 0.5))
for root in ["[]", "[1,2]", "42", '"str"', "null"]:
    cases.append((root, False))

for keys, jsonc in cases:
    ext = ".jsonc" if (isinstance(keys, list) and jsonc) else ".json"
    doc = doc_for(keys, jsonc) if isinstance(keys, list) else keys
    expect = "PASS" if (isinstance(keys, list) and set(keys) <= ALLOWED) else "FAIL"
    print(f"{expect} {ext} {base64.b64encode(doc.encode()).decode()}")
PY
  _gen_rc=$?
  [[ "$_gen_rc" -eq 0 ]] || { echo "  ✗ (j) case generator exited $_gen_rc"; ok=0; }
  _n=$(wc -l < "$_cases/spec")
  [[ "$_n" -eq 34 ]] || { echo "  ✗ (j) expected 34 generated cases, got $_n"; ok=0; }
  # shellcheck disable=SC2312  # decoder status is checked inline
  while read -r _expect _ext _b64 _rest; do
    # The record SHAPE is load-bearing too (#730). The line count above proves
    # how many records arrived, not that any of them is well-formed: a truncated
    # record such as `FAIL .json` leaves _b64 empty, decodes to an empty config,
    # and that config refuses — so _got=FAIL matches the expectation and a
    # broken generator re-certifies itself green. No sentinel for "valid empty
    # payload" is needed because the generator never emits one: doc_for always
    # emits at least `{`/`}`, and every root-literal case is a non-empty string.
    # The base64 pattern spells out whole 4-char quanta with canonical padding
    # rather than `[A-Za-z0-9+/]+=*`, which accepts junk like `A=` / `A===`; the
    # quanta form also matches the empty string, hence the explicit -z guard.
    if [[ ! "$_expect" =~ ^(PASS|FAIL)$ ]] || [[ ! "$_ext" =~ ^\.jsonc?$ ]] \
       || [[ -z "$_b64" ]] \
       || [[ ! "$_b64" =~ ^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$ ]] \
       || [[ -n "$_rest" ]]; then
      echo "  ✗ (j) malformed generated case record: $_expect $_ext $_b64 $_rest"; ok=0; break
    fi
    # Clear BOTH canonical paths first — a stale file under the other
    # extension would mask or corrupt this case's expectation.
    rm -f "$_cases/home/.opencode/opencode.json" "$_cases/home/.opencode/opencode.jsonc"
    printf '%s' "$_b64" | python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read().strip()))' > "$_cases/home/.opencode/opencode$_ext" || { echo "  ✗ (j) case decode failed"; ok=0; break; }
    if validate_opencode_home_config "$_cases/home" 2>/dev/null; then _got=PASS; else _got=FAIL; fi
    [[ "$_got" == "$_expect" ]] || { echo "  ✗ (j) case .opencode$_ext expected $_expect got $_got"; ok=0; }
  done < "$_cases/spec"
  rm -rf "$_cases"

  exit $((1 - ok))
); then
  pass "validate_opencode_home_config: provider-only pass, mcp/unparseable refuse, JSONC-tolerant, -I isolated"
else
  fail "validate_opencode_home_config behavioral assertions failed (see above)"
fi
# The fault child exists ONLY to exercise the (j) block above, so stop here
# rather than re-running the remaining ~400 lines of unrelated assertions a
# second time (#762). Unbounded, the recursion nearly doubles this suite against
# run-shell-tests.sh's shared 180s per-test budget, which this file has no
# override for — headroom a slower/shared CI runner can exhaust before ever
# reaching the (j2) assertion. `finish` keeps the child's exit status on the
# same accounting as a full run.
[[ "$FAULT_GENERATOR" == 1 ]] && finish
# (j2, #730) Prove the guard above can actually fail: re-run this file with a
# crashing case generator and require a non-zero exit, the generator guard's own
# diagnostic, and the absence of the green property line. The middle condition
# is load-bearing — without it any early child failure (one that never reached
# the generator) would satisfy the other two and certify a guard that never ran.
# Skipped in the fault child itself — that is what keeps the re-run from recursing.
# Both matches use a herestring, NOT `printf | grep -q`: under this file's
# `set -o pipefail`, an early-exiting `grep -q` can SIGPIPE the producer, making
# the pipeline status 141 regardless of whether the pattern matched. On the
# negated match that inverts into a fail-OPEN — grep FINDS the green line (which
# must fail this assertion), the pipeline reports 141, `!` flips it to true, and
# the very fail-open this block exists to detect passes instead. A herestring
# has no producer to signal, so grep's own status is the status.
if [[ "$FAULT_GENERATOR" == 0 ]]; then
  _fault_out="$(bash "${BASH_SOURCE[0]}" --fault-generator 2>&1)"; _fault_rc=$?
  if [[ "$_fault_rc" -ne 0 ]] \
     && grep -qF '✗ (j) case generator exited' <<<"$_fault_out" \
     && ! grep -qF 'validate_opencode_home_config: provider-only pass' <<<"$_fault_out"; then
    pass "(j) injected generator failure fails the suite without the green property assertion"
  else
    fail "(j) injected generator failure still exited $_fault_rc / printed the property assertion (fail-open)"
  fi
fi
# (g) BOTH opencode arms call the shared guard before dispatch.
# shellcheck disable=SC2016  # single-quoted patterns are grep regexes, not shell expansions
if grep -q 'validate_opencode_home_config "\$_ER_OC_HOME"' "$RC" \
   && grep -q 'validate_opencode_home_config "\$_oc_home"' "$DP"; then
  pass "both opencode arms (execute_review + dispatch.sh) call validate_opencode_home_config"
else
  fail "an opencode arm is missing the validate_opencode_home_config call"
fi
# (h) dispatch.sh keeps the pi-required PATH-resolved bash shebang (the pi
# lane needs bash 4+ via PATH — a `#!/bin/bash` shebang would pin /bin/bash
# 3.2) WITH `-p` (`#!/usr/bin/env -S bash -p`): the first process is
# privileged, so no BASH_FUNC_* shadow is imported from the start, and the
# nonce+sentinel re-exec guard precedes set -euo pipefail (a shadowed `set`
# must not run before the guard).
# shellcheck disable=SC2016,SC2312  # single-quoted patterns; head/cut in pipeline are not load-bearing
if grep -qE '^#!/usr/bin/env -S bash -p$' "$DP" \
   && grep -qF 'exec "$BASH" -p "$0" "_bd_priv_${_bd_nonce}" "$@"' "$DP" \
   && grep -q 'type -t _bd_sentinel' "$DP" \
   && [[ "$(grep -nF 'exec "$BASH" -p' "$DP" | head -1 | cut -d: -f1)" -lt "$(grep -n 'set -euo pipefail' "$DP" | head -1 | cut -d: -f1)" ]]; then
  pass "dispatch.sh keeps env-resolved -p bash shebang + nonce+sentinel re-exec backstop before set -euo"
else
  fail "dispatch.sh missing/incorrectly-placed function-clean boundary"
fi
# (i) privileged bash suppresses imported function shadows (the mechanism the
# re-exec relies on) — verified on the repo's target /bin/bash 3.2. Uses a
# non-command name (_mechpoison) so the test itself never shadows a real tool.
# shellcheck disable=SC2329  # _mechpoison invoked inside the /bin/bash -c strings
_mechpoison() { echo MECH-POISONED; }
export -f _mechpoison
if /bin/bash -c '_mechpoison' 2>&1 | grep -q MECH-POISONED \
   && ! /bin/bash -p -c '_mechpoison' 2>&1 | grep -q MECH-POISONED; then
  unset -f _mechpoison
  pass "privileged bash (-p) suppresses imported function shadows (3.2-verified mechanism)"
else
  unset -f _mechpoison
  fail "privileged bash does not suppress imported function shadows (re-exec is ineffective)"
fi
# (j) function-clean boundary: (a) the `-p`-in-shebang (env -S bash -p) keeps
# poisoned exec/set shadows INERT (the first process imports nothing); (b) a
# naive exec shadow (returns without re-exec'ing) aborts; (c) a FORGED
# re-exec (exec shadow calls builtin exec WITHOUT -p but WITH the marker) is
# caught by the sentinel probe — the script refuses to continue; (d) a source
# shadow never runs (the guard does not call source before the re-exec).
if (
  set -uo pipefail
  # (a) shebang path (the harness invocation): poisons never imported
  exec() { echo EXEC-POISONED; }
  set() { echo SET-POISONED; }
  export -f exec set
  out="$(echo test | "$DP" --help 2>&1)"; rc=$?
  [[ "$rc" -eq 0 ]] || { echo "  ✗ (j-a) dispatch failed under poisoned env (rc=$rc)"; exit 1; }
  printf '%s' "$out" | grep -q "EXEC-POISONED\|SET-POISONED" && { echo "  ✗ (j-a) poison ran via shebang"; exit 1; }
  # (b) naive exec shadow → abort, no continuation
  exec() { echo EXEC-POISONED; }
  export -f exec
  out2="$(bash "$DP" --help 2>&1)"; rc2=$?
  [[ "$rc2" -ne 0 ]] || { echo "  ✗ (j-b) naive exec shadow continued (rc=0)"; exit 1; }
  printf '%s' "$out2" | grep -q "refusing to continue" || { echo "  ✗ (j-b) missing abort"; exit 1; }
  # (c) FORGED re-exec: the exec shadow re-execs WITHOUT -p but WITH the
  # marker (script called: exec /bin/bash -p "$0" _bd_priv "$@" → shadow sees
  # $1=/bin/bash $2=-p $3=script $4=_bd_priv $5+=orig). The re-exec'd process
  # imports the sentinel → the sentinel probe refuses continuation.
  exec() { echo EXEC-FORGED; builtin exec /bin/bash "$3" "$4" "${@:5}"; }
  export -f exec
  out3="$(bash "$DP" --help 2>&1)"; rc3=$?
  [[ "$rc3" -ne 0 ]] || { echo "  ✗ (j-c) forged re-exec continued unprivileged (rc=0)"; exit 1; }
  printf '%s' "$out3" | grep -q "refusing to continue" || { echo "  ✗ (j-c) sentinel abort missing"; exit 1; }
  printf '%s' "$out3" | grep -q "EXEC-FORGED" || { echo "  ✗ (j-c) forged exec did not run"; exit 1; }
  printf '%s' "$out3" | grep -q "Usage:" && { echo "  ✗ (j-c) script continued past the guard"; exit 1; }
  # (d) source shadow: must never run (the guard calls no source before the
  # re-exec; exec is forwarded to the real builtin so the privileged child
  # runs and --help exits clean)
  exec() { builtin exec "$@"; }
  source() { echo SRC-POISONED; }
  export -f exec source
  out4="$(bash "$DP" --help 2>&1)"; rc4=$?
  [[ "$rc4" -eq 0 ]] || { echo "  ✗ (j-d) dispatch failed under source poison (rc=$rc4)"; exit 1; }
  printf '%s' "$out4" | grep -q "SRC-POISONED" && { echo "  ✗ (j-d) source shadow ran"; exit 1; }
  # (e) a caller-supplied BARE marker (_bd_priv, no nonce) must not bypass
  # the boundary: the guard re-execs anyway (bare never matches
  # "_bd_priv_<nonce>"), so under a naive exec shadow it aborts instead of
  # continuing unprivileged.
  exec() { echo EXEC-POISONED; }
  export -f exec
  out5="$(bash "$DP" _bd_priv --help 2>&1)"; rc5=$?
  [[ "$rc5" -ne 0 ]] || { echo "  ✗ (j-e) bare marker bypassed the boundary (rc=0)"; exit 1; }
  printf '%s' "$out5" | grep -q "refusing to continue" || { echo "  ✗ (j-e) missing abort on bare-marker attempt"; exit 1; }
  printf '%s' "$out5" | grep -q "EXEC-POISONED" || { echo "  ✗ (j-e) exec shadow did not run (guard never re-exec'd?)"; exit 1; }
  # (f) empty-nonce marker (_bd_priv_ with no env nonce) must also fall
  # through to the re-exec → same abort under a naive exec shadow.
  out6="$(bash "$DP" _bd_priv_ --help 2>&1)"; rc6=$?
  [[ "$rc6" -ne 0 ]] || { echo "  ✗ (j-f) empty-nonce marker bypassed the boundary (rc=0)"; exit 1; }
  printf '%s' "$out6" | grep -q "refusing to continue" || { echo "  ✗ (j-f) missing abort on empty-nonce attempt"; exit 1; }
  # (g) dual-forge (matching env nonce + argv marker, no code execution): the
  # re-exec branch was skipped so the sentinel was never exported — the env-
  # presence check aborts.
  out7="$(_bd_nonce=known bash "$DP" _bd_priv_known --help 2>&1)"; rc7=$?
  [[ "$rc7" -ne 0 ]] || { echo "  ✗ (j-g) dual-forge bypassed the boundary (rc=0)"; exit 1; }
  printf '%s' "$out7" | grep -q "refusing to continue" || { echo "  ✗ (j-g) missing abort on dual-forge attempt"; exit 1; }
  # (h) substring forge (an env var whose VALUE contains the sentinel name):
  # printenv's exact NAME lookup must not be fooled by a value match.
  out8="$(_bd_nonce=known X='BASH_FUNC__bd_sentinel%%' bash "$DP" _bd_priv_known --help 2>&1)"; rc8=$?
  [[ "$rc8" -ne 0 ]] || { echo "  ✗ (j-h) substring-forge bypassed the boundary (rc=0)"; exit 1; }
  printf '%s' "$out8" | grep -q "refusing to continue" || { echo "  ✗ (j-h) missing abort on substring-forge attempt"; exit 1; }
  # (i) env-NAME forge with a NON-function value (via `env`): the sentinel
  # value check (must start with "() {" and end with "}") refuses it.
  out9="$(env '_bd_nonce=known' 'BASH_FUNC__bd_sentinel%%=x' bash "$DP" _bd_priv_known --help 2>&1)"; rc9=$?
  [[ "$rc9" -ne 0 ]] || { echo "  ✗ (j-i) env-NAME forge bypassed the boundary (rc=0)"; exit 1; }
  printf '%s' "$out9" | grep -q "refusing to continue" || { echo "  ✗ (j-i) missing abort on env-NAME forge"; exit 1; }
  # (j) TRUNCATED-function forge: `BASH_FUNC__bd_sentinel%%='() {'` (no closing
  # brace) is NOT imported on bash 5.x but satisfies a bare "() {" prefix — the
  # trailing-`}` shape check must refuse it.
  out10="$(env '_bd_nonce=known' 'BASH_FUNC__bd_sentinel%%=() {' bash "$DP" _bd_priv_known --help 2>&1)"; rc10=$?
  [[ "$rc10" -ne 0 ]] || { echo "  ✗ (j-j) truncated-function forge bypassed the boundary (rc=0)"; exit 1; }
  printf '%s' "$out10" | grep -q "refusing to continue" || { echo "  ✗ (j-j) missing abort on truncated-function forge"; exit 1; }
  exit 0
); then
  pass "function-clean boundary: shebang inert; naive+forged exec shadows abort; source shadow never runs"
else
  fail "function-clean boundary failed (see above)"
fi

# ── 10. Operator-username allowlist refuses tilde SPECIAL forms ─────
# `eval echo "~$u"` must never see a name that starts with `-`, `+`, or a
# digit: `~-`/`~-0` expand to $OLDPWD/$PWD, `~+`/`~0` to $PWD — a special-form
# "username" would make the reviewed checkout the "trusted home". Behavioral
# test on the REAL helper (sourced, not copied).
if ( # shellcheck disable=SC1090,SC2016  # source target is a variable; '$u' is a literal grep pattern
     source "$RC" && _bd_valid_username "vfrvndtt" && _bd_valid_username "0abc" \
     && ! _bd_valid_username "-0" && ! _bd_valid_username "-" && ! _bd_valid_username "+1" \
     && ! _bd_valid_username "7" && ! _bd_valid_username "-" && ! _bd_valid_username "a;rm" \
     && ! _bd_valid_username 'a b' && ! _bd_valid_username "" ); then
  pass "username allowlist: plain + digit-leading ok, tilde-stack/metachar/empty refused"
else
  fail "username allowlist: a tilde-stack or metacharacter name passed validation"
fi
# #789 round 4: the validator moved off shadowable `return` (an exported
# BASH_FUNC_return%% made an all-digit username pass and let the shadow write
# _trusted_operator_home's globals), so the tilde-stack regex now sits on an
# `elif`. Same regex, same rejection — the behavioural assertion above proves the
# semantics; this pin only proves the guard is still PRESENT.
# shellcheck disable=SC2016  # single-quoted pattern is a literal grep for source text
if grep -qF 'elif [[ "$1" =~ ^[-+]?[0-9]*$ ]]; then' "$RC"; then
  pass "resolve-cli.sh: allowlist rejects tilde stack forms (^[-+]?[0-9]*$)"
else
  fail "resolve-cli.sh: allowlist does not reject tilde stack forms"
fi
# shellcheck disable=SC2016  # single-quoted pattern is a literal grep for the pi-probe source text
if [[ "$(grep -cF '[[ "$u" =~ ^[-+]?[0-9]*$ ]] && exit 1' "$DP")" -eq 2 ]]; then
  pass "dispatch.sh pi probes: both username checks reject tilde stack forms"
else
  fail "dispatch.sh pi probes: username checks missing tilde-stack guard"
fi

# ── 11. #541 — banner-only opencode output must reach the empty-output guard ──
# Both opencode execution sites share one false-success mechanism: `opencode
# run` prints "> busdriver-review · <model>" (+ blank lines) UNCONDITIONALLY, so
# a run that produced NO assistant text is 32 bytes of "output" — the generic
# byte-size/empty-string guards cannot fire, the retry never runs, and a
# content-free result reports as success. The fix normalizes the banner away AT
# EACH SITE via one canonical predicate (_oc_output_is_banner_only in
# resolve-cli.sh, fallback copy in dispatch.sh), so guard/retry/MECHANISM_FAILED
# work untouched. 11a executes the REAL dispatch.sh block; 11b executes the
# REAL _run_review_with_retries — both mutation-biting.
# shellcheck source=/dev/null
source "$RC"
# ── 11a. dispatch.sh file-based site ──────────────────────────────
# The arm's block, extracted verbatim (not a copy) and run against fixtures:
# deleting or weakening it fails the banner-only case (extraction goes empty →
# eval no-ops → outfile keeps its bytes). The canonical predicate comes from
# the sourced $RC, so weakening the predicate fails here too.
OC_BLOCK="$(awk '/#541: opencode prints/{f=1} f{print} f&&/^ +fi *$/{exit}' "$DP")"
_oc_norm_case() { # $1=fixture-content-file $2=label $3=expected-bytes-after (-1 = unchanged)
  local fx="$1" label="$2" expect="$3" before after work cap
  [[ -s "$fx" ]] || { fail "$label: empty fixture"; return; }
  before=$(wc -c < "$fx" | tr -d ' ')
  work="$(mktemp "${TMPDIR:-/tmp}/oc541.XXXXXX")"
  cp "$fx" "$work"
  # The block runs in an `if` condition whose stdout is the caller's — a
  # classifier that PRINTS matched lines would leak the verdict text here.
  # Capture and require silence (litmus round-2 finding).
  cap="$( { # shellcheck disable=SC2034  # outfile is consumed by the evaluated block, not this shell
    outfile="$work"; eval "$OC_BLOCK"; } 2>&1 )" || { fail "$label: block errored"; rm -f "$work"; return; }
  after=$(wc -c < "$work" | tr -d ' ')
  rm -f "$work"
  if [[ -n "$cap" ]]; then
    fail "$label: block emitted output (${cap:0:40}…)"
    return
  fi
  if [[ "$expect" == "-1" ]]; then
    if [[ "$after" -eq "$before" ]]; then
      pass "$label"
    else
      fail "$label: output changed ($before → $after bytes)"
    fi
  elif [[ "$after" -eq "$expect" ]]; then
    pass "$label"
  else
    fail "$label: expected $expect bytes, got $after"
  fi
}
FIX="$(mktemp "${TMPDIR:-/tmp}/oc541fix.XXXXXX")" || exit 1
# The exact artifact from the issue: banner + blank lines, nothing else.
printf '\n> busdriver-review · kimi-k3\n\n' > "$FIX"
_oc_norm_case "$FIX" "banner-only outfile truncates to byte-empty → retry guard can fire" 0
# Healthy run: banner + substantive verdict. Every byte must survive unchanged.
printf '\n> busdriver-review · kimi-k3\n\nPONG\n' > "$FIX"
_oc_norm_case "$FIX" "healthy opencode output is byte-identical" -1
# ANSI-styled banner-only run must still classify as empty (the predicate
# strips ANSI escapes before classifying).
printf '\033[1m> busdriver-review · kimi-k3\033[0m\n\n' > "$FIX"
_oc_norm_case "$FIX" "ANSI-styled banner-only outfile truncates to byte-empty" 0
# A Markdown quotation containing '·' is substantive prose, not a banner; the
# setup-bail reason written to $outfile must survive too (the batch banner
# reads it).
printf '> substantive verdict · confidence 95\n' > "$FIX"
_oc_norm_case "$FIX" "markdown quote with middot survives normalization" -1
printf 'Skipped: no usable .auditor.model and no --model — auditor not dispatched\n' > "$FIX"
_oc_norm_case "$FIX" "setup-bail reason survives normalization" -1
# Malformed UTF-8 must ALSO survive: sed exits non-zero on invalid bytes in a
# multibyte locale, and a negated pipeline would invert that processing error
# into "banner-only" and truncate the review (litmus round-3 finding). The
# classifier treats processing failure as "not banner-only".
printf '\n> busdriver-review · kimi-k3\n\n\xff\xfePONG\n' > "$FIX"
_oc_norm_case "$FIX" "malformed UTF-8 healthy output survives (fail-closed)" -1
# A Markdown blockquote that QUOTES the banner plus a verdict is substantive
# prose — the exemption must match THE literal banner line (whole line, one
# token after the middot), not any line that merely begins like one (litmus
# round-4 finding).
printf '> busdriver-review · final verdict: no issues found\n' > "$FIX"
_oc_norm_case "$FIX" "banner-quoting verdict survives (whole-line anchor)" -1
rm -f "$FIX"
# Fail-closed, sed side (deterministic on any platform/locale): inject a sed
# stub that exits 2. The malformed-UTF-8 fixture only makes sed fail in a
# multibyte locale — under C, sed accepts the bytes and cannot bite the
# `|| return 1` guard — so this stub is the locale-independent bite (litmus
# commit-mode finding).
_sd_stub="$(mktemp -d "${TMPDIR:-/tmp}/oc541sed.XXXXXX")" || exit 1
printf '#!/bin/sh\nexit 2\n' > "$_sd_stub/sed"
chmod +x "$_sd_stub/sed"
if PATH="$_sd_stub:/usr/bin:/bin" _oc_output_is_banner_only <<'EOF'
substantive output must survive a sed error
EOF
then
  fail "banner predicate: sed error (status 2) classified as banner-only (fail-open truncation)"
else
  pass "banner predicate fails closed on injected sed error"
fi
rm -rf "$_sd_stub"
# Fail-closed, awk side (litmus round-6 finding): if awk and grep BOTH fail,
# pipefail surfaces grep's rightmost status ("no match" = 1), which would
# mask the awk error as banner-only. Inject an awk stub that exits 2 — the
# predicate must still keep the output.
_awk_stub="$(mktemp -d "${TMPDIR:-/tmp}/oc541awk.XXXXXX")" || exit 1
printf '#!/bin/sh\nexit 2\n' > "$_awk_stub/awk"
chmod +x "$_awk_stub/awk"
if PATH="$_awk_stub:/usr/bin:/bin" _oc_output_is_banner_only <<'EOF'
substantive output must survive an awk error
EOF
then
  fail "banner predicate: awk error (status 2) classified as banner-only (fail-open truncation)"
else
  pass "banner predicate fails closed on injected awk error"
fi
rm -rf "$_awk_stub"
# Fail-closed, grep side: a grep execution error (status 2) must NOT be
# classified as banner-only — explicit status handling keeps the output
# (litmus round-5 finding). Inject a grep stub that always exits 2.
# (The malformed-UTF-8 fixture above is the sed-side real-world coverage; a
# missing-input redirect would fail before the predicate executes, so it
# cannot exercise the predicate and is deliberately not used.)
_grp_stub="$(mktemp -d "${TMPDIR:-/tmp}/oc541grep.XXXXXX")" || exit 1
printf '#!/bin/sh\nexit 2\n' > "$_grp_stub/grep"
chmod +x "$_grp_stub/grep"
if PATH="$_grp_stub:/usr/bin:/bin" _oc_output_is_banner_only <<'EOF'
substantive output must survive a grep error
EOF
then
  fail "banner predicate: grep error (status 2) classified as banner-only (fail-open truncation)"
else
  pass "banner predicate fails closed on injected grep error"
fi
rm -rf "$_grp_stub"
# Wiring: the arm calls the shared predicate, and dispatch.sh carries the
# fallback copy for the resolve-cli.sh-missing degraded path (repo convention
# for shared classifiers — keep in sync).
# shellcheck disable=SC2016  # single-quoted patterns are grep regexes, not shell expansions
if grep -q 'if _oc_output_is_banner_only < "\$outfile"' "$DP" \
   && grep -q 'if ! type _oc_output_is_banner_only &>/dev/null; then' "$DP"; then
  pass "dispatch.sh: arm wired to _oc_output_is_banner_only + fallback copy present"
else
  fail "dispatch.sh: arm/fallback wiring for _oc_output_is_banner_only missing"
fi
# The fallback copy in dispatch.sh is behaviorally exercised too: the
# fixtures above source resolve-cli.sh (canonical), so a divergent fallback
# would pass them. This defines the fallback in isolation (canonical unset)
# and asserts the same three classifications (litmus PR-mode finding).
OC_FALLBACK="$(awk '/# #541: True/{f=1} f{print} f&&/^fi$/{exit}' "$DP")"
if (
  set -uo pipefail
  unset -f _oc_output_is_banner_only 2>/dev/null || true
  eval "$OC_FALLBACK"
  # Sed failure must be exercised DETERMINISTICALLY (a stub exiting 2): the
  # malformed-UTF-8 fixture only fails under a multibyte locale — under C,
  # sed accepts the bytes and the guard removal would go unpunished.
  _fsd_stub="$(mktemp -d "${TMPDIR:-/tmp}/oc541fsed.XXXXXX")" || exit 1
  printf '#!/bin/sh\nexit 2\n' > "$_fsd_stub/sed"
  chmod +x "$_fsd_stub/sed"
  ok=1
  printf '\n> busdriver-review · kimi-k3\n\n' | _oc_output_is_banner_only || ok=0
  printf '\n> busdriver-review · kimi-k3\n\nPONG\n' | _oc_output_is_banner_only && ok=0
  if PATH="$_fsd_stub:/usr/bin:/bin" _oc_output_is_banner_only <<'EOF'
substantive output must survive a sed error
EOF
  then ok=0; fi
  rm -rf "$_fsd_stub"
  exit $((1 - ok))
); then
  pass "dispatch.sh fallback copy classifies banner-only / substantive / sed-error identically"
else
  fail "dispatch.sh fallback copy diverges from canonical classification"
fi
# Preservation invariant (litmus PR-mode finding): every input OUTSIDE the
# exact blank/banner grammar stays substantive — the classifier must never
# eat prose. Representative non-banner lines, each asserted not banner-only.
if (
  set -uo pipefail
  ok=1
  for line in \
    'PONG' \
    '> busdriver-review · kimi-k3 with trailing verdict prose' \
    '> busdriver-review · final verdict: no issues found' \
    '> busdriver-review kimi-k3 (no middot)' \
    '·' \
    '> other-agent · kimi-k3' \
    '## heading' \
    '- list item' \
    '{"status":"pass","issues":[]}' \
    '    > busdriver-review · kimi-k3' \
  ; do
    printf '%s\n' "$line" | _oc_output_is_banner_only \
      && { echo "  ✗ preservation: '$line' classified as banner-only"; ok=0; }
  done
  # PR-review combination: a valid banner followed by a banner-shaped
  # substantive line must stay substantive — only the FIRST non-blank line
  # is the real banner (opencode prints exactly one).
  printf '> busdriver-review · kimi-k3\n> busdriver-review · PASS\n' | _oc_output_is_banner_only \
    && { echo "  ✗ preservation: banner + banner-shaped verdict classified banner-only"; ok=0; }
  # The same combination through the eval'd dispatch block: byte-identical.
  _combo="$(mktemp "${TMPDIR:-/tmp}/oc541combo.XXXXXX")" || exit 1
  printf '> busdriver-review · kimi-k3\n> busdriver-review · PASS\n' > "$_combo"
  _before=$(wc -c < "$_combo" | tr -d ' ')
  ( # shellcheck disable=SC2034  # outfile is consumed by the evaluated block, not this shell
    outfile="$_combo"; eval "$OC_BLOCK" )
  _after=$(wc -c < "$_combo" | tr -d ' ')
  rm -f "$_combo"
  [[ "$_after" -eq "$_before" ]] || { echo "  ✗ preservation: combo truncated through dispatch block ($_before → $_after bytes)"; ok=0; }
  exit $((1 - ok))
); then
  pass "preservation: non-banner lines stay substantive"
else
  fail "preservation: a non-banner line was classified as banner-only"
fi
# ── 11b. resolve-cli.sh variable-based site ───────────────────────
# Run the REAL retry wrapper with a stub "opencode" that prints ONLY the banner
# and exits 0. Pre-#541 that classified as success (the banner passes the
# non-empty check and carries no transient token). With the fix the banner-only
# capture normalizes to empty → the wrapper's empty-verdict path marks the run
# FAILED (rc=1, no output). Healthy control: banner + PONG succeeds unchanged.
# stdin mode `none` (stub takes no prompt on fd 0) avoids the pipefail SIGPIPE
# class; RETRIES=0/RETRY_DELAY=0 keep the test instant.
if (
  set -uo pipefail
  BUSDRIVER_CLI_RETRIES=0 BUSDRIVER_CLI_RETRY_DELAY=0
  export BUSDRIVER_CLI_RETRIES BUSDRIVER_CLI_RETRY_DELAY
  ok=1
  out=""; rc=0
  out=$(_run_review_with_retries opencode "probe" 5 none \
    sh -c 'printf "\n> busdriver-review · kimi-k3\n\n"') || rc=$?
  [[ "$rc" -eq 1 && -z "$out" ]] \
    || { echo "  ✗ banner-only stub → rc=$rc out=${out:-<empty>} (expected rc=1, empty)"; ok=0; }
  # Healthy control must be BYTE-IDENTICAL: a predicate that prints matched
  # lines while classifying would duplicate the review text into the returned
  # output (litmus round-2 finding). Note: $(...) strips trailing newlines, so
  # expected matches the captured value, not the stub's raw stdout.
  expected=$'\n> busdriver-review · kimi-k3\n\nPONG'
  out=""; rc=0
  out=$(_run_review_with_retries opencode "probe" 5 none \
    sh -c 'printf "\n> busdriver-review · kimi-k3\n\nPONG\n"') || rc=$?
  [[ "$rc" -eq 0 && "$out" == "$expected" ]] \
    || { echo "  ✗ healthy stub → rc=$rc out=${out:-<empty>} (expected byte-identical stdout)"; ok=0; }
  exit $((1 - ok))
); then
  pass "banner-only _run_review_with_retries marks failure (rc=1, empty); healthy run succeeds"
else
  fail "banner normalization missing/weakened in _run_review_with_retries"
fi
finish
