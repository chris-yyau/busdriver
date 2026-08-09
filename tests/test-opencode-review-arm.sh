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
  trap 'rm -rf "$_home"' EXIT

  # (a) provider-only json → pass
  printf '{"provider":{"opencode-go-lb":{"options":{"baseURL":"http://127.0.0.1:8788/v1","apiKey":"x"}}}}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null || { echo "  ✗ (a) provider-only json refused"; ok=0; }

  # (b) mcp key → refuse
  printf '{"provider":{},"mcp":{"x":{"type":"stdio","command":"/bin/echo"}}}\n' > "$_home/.opencode/opencode.json"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (b) mcp key accepted"; ok=0; }

  # (c) provider-only jsonc WITH comments + trailing commas → pass (JSONC-tolerant)
  rm -f "$_home/.opencode/opencode.json"
  printf '{\n  // balancer provider\n  "provider": {\n    "opencode-go-lb": {\n      "options": {},\n    },\n  },\n}\n' > "$_home/.opencode/opencode.jsonc"
  validate_opencode_home_config "$_home" 2>/dev/null || { echo "  ✗ (c) provider-only jsonc (comments/trailing commas) refused"; ok=0; }

  # (d) garbage → refuse (fail-closed on unparseable)
  printf 'not json at all {\n' > "$_home/.opencode/opencode.jsonc"
  validate_opencode_home_config "$_home" 2>/dev/null && { echo "  ✗ (d) unparseable jsonc accepted"; ok=0; }

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

  # (g) BASH_FUNC_python3%% environment poison: the validator runs in a
  # sterile child (/usr/bin/env -i) with an ABSOLUTE interpreter, so an
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

  # (j) seeded property sweep: random key subsets x {strict, JSONC} over the
  # allowlist, plus non-object roots. Oracle: PASS iff the parsed root is an
  # object whose keys are ⊆ {provider, $schema}. Seeded RNG → deterministic.
  # The validator reads only the CANONICAL opencode.json/.jsonc paths, so the
  # generator emits spec lines (expect, ext, base64 doc) and the bash loop
  # materializes + validates each case individually.
  _cases="$(mktemp -d)" || exit 1
  mkdir -p "$_cases/home/.opencode"
  # shellcheck disable=SC2312  # decoder status is checked; generator status is not load-bearing
  while read -r _expect _ext _b64; do
    printf '%s' "$_b64" | python3 -c 'import sys,base64; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read().strip()))' > "$_cases/home/.opencode/opencode$_ext" || { echo "  ✗ (j) case decode failed"; ok=0; break; }
    if validate_opencode_home_config "$_cases/home" 2>/dev/null; then _got=PASS; else _got=FAIL; fi
    [[ "$_got" == "$_expect" ]] || { echo "  ✗ (j) case .opencode$_ext expected $_expect got $_got"; ok=0; }
  done < <(python3 - "$_cases" <<'PY'
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
)
  rm -rf "$_cases"

  exit $((1 - ok))
); then
  pass "validate_opencode_home_config: provider-only pass, mcp/unparseable refuse, JSONC-tolerant, -I isolated"
else
  fail "validate_opencode_home_config behavioral assertions failed (see above)"
fi
# (g) BOTH opencode arms call the shared guard before dispatch.
# shellcheck disable=SC2016  # single-quoted patterns are grep regexes, not shell expansions
if grep -q 'validate_opencode_home_config "\$_oc_home"' "$RC" \
   && grep -q 'validate_opencode_home_config "\$_oc_home"' "$DP"; then
  pass "both opencode arms (execute_review + dispatch.sh) call validate_opencode_home_config"
else
  fail "an opencode arm is missing the validate_opencode_home_config call"
fi
# (h) dispatch.sh starts privileged via the -p shebang with a sentinel-verified
# re-exec backstop for non-shebang invocations; the re-exec guard itself must
# precede set -euo pipefail (a shadowed `set` must not run before the guard).
# shellcheck disable=SC2016,SC2312  # single-quoted patterns; head/cut in pipeline are not load-bearing
if grep -q '^#!/bin/bash -p' "$DP" \
   && grep -q 'exec /bin/bash -p "\$0" "_bd_priv_\${_bd_nonce}" "\$@"' "$DP" \
   && grep -q 'type -t _bd_sentinel' "$DP" \
   && [[ "$(grep -n 'exec /bin/bash -p' "$DP" | head -1 | cut -d: -f1)" -lt "$(grep -n 'set -euo pipefail' "$DP" | head -1 | cut -d: -f1)" ]]; then
  pass "dispatch.sh starts privileged (-p shebang) with nonce+sentinel-verified re-exec backstop before set -euo"
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
# (j) function-clean boundary: (a) the -p shebang keeps poisoned exec/set
# shadows inert; (b) a naive exec shadow (returns without re-exec'ing) aborts;
# (c) a FORGED re-exec (exec shadow calls builtin exec WITHOUT -p but WITH the
# marker) is caught by the sentinel probe — the script refuses to continue;
# (d) a source shadow never runs (the guard does not call source before the
# re-exec).
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
  exit 0
); then
  pass "function-clean boundary: shebang inert; naive+forged exec shadows abort; source shadow never runs"
else
  fail "function-clean boundary failed (see above)"
fi

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "PASS (test-opencode-review-arm)"
  exit 0
fi
echo "FAIL: $FAILURES assertion(s) (test-opencode-review-arm)"
exit 1
