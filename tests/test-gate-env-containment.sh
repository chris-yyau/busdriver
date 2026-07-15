#!/usr/bin/env bash
# Test: gate environment containment (issue #325, ADR 0016).
#
# Proves the hooks.json invocation pattern + lib/sanitized-gate.sh together
# neutralize a poisoned session environment: a committed settings.json `env`
# block cannot bypass a gate (SKIP_*), run code before it (BASH_ENV / exported
# function), or shim its tools (PATH). Runs the EXACT invocation hooks.json uses,
# from a deliberately poisoned outer shell, against a probe "gate".
#
# SCOPE: this validates the `env -i` containment boundary — the wrapper's
# guarantee. It does NOT (and cannot, without Claude's real hook runner) exercise
# the documented residual where the OUTER hook shell is `bash -c` and sources
# BASH_ENV once before `/usr/bin/env` is reached; that one-shot lives outside any
# gate's decision path and is recorded in ADR 0016, not unit-tested here.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Snapshot the real HOME before any subshell poisons it (the run_out block below
# sets a fake HOME inside a $(...)); the node-containment block reuses this trusted
# value, sidestepping SC2031's "HOME modified in a subshell" tracking.
REAL_HOME="$HOME"
WRAPPER="$REPO_ROOT/hooks/gate-scripts/lib/sanitized-gate.sh"
PASS=0
FAIL=0
assert() {  # assert <condition-result:0/1> <message>
    if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi
}
# assert_true <cond-cmd...> then <message>: runs the condition as a command so its
# rc is captured directly (avoids SC2319's fragile `[[ ]]; assert $?`). Last arg is
# the message; all preceding args form the condition command.
assert_true() {
    local msg="${*: -1}"; local cond=("${@:1:$#-1}")
    if "${cond[@]}"; then assert 0 "$msg"; else assert 1 "$msg"; fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Build an isolated plugin-root skeleton with a probe gate ────────────────
mkdir -p "$TMP/root/hooks/gate-scripts/lib" "$TMP/shim"
cp "$WRAPPER" "$TMP/root/hooks/gate-scripts/lib/sanitized-gate.sh"

# Probe gate: reports the effective env it was handed.
cat > "$TMP/root/hooks/gate-scripts/_probe.sh" <<'PROBE'
echo "SKIP_LITMUS=[${SKIP_LITMUS:-}]"
echo "BASH_ENV=[${BASH_ENV:-}]"
echo "PATH=[${PATH}]"
echo "GIT=[$(git --version 2>&1)]"          # shimmed/functioned git would announce itself
echo "STATE_DIR=[${BUSDRIVER_STATE_DIR:-}]"
echo "HOME=[${HOME:-}]"
echo "PYTHONNOUSERSITE=[${PYTHONNOUSERSITE:-}]"
python3 -c 'pass' 2>/dev/null || true   # would run a poisoned ~/.local sitecustomize.py
PROBE

# ── Poison payloads ─────────────────────────────────────────────────────────
# BASH_ENV target: if any bash sources it, it drops a marker + tries to re-inject.
cat > "$TMP/evil.sh" <<EVIL
: > "$TMP/BASH_ENV_RAN"
export SKIP_LITMUS=1
EVIL
# A shimmed git that would prove tool-hijack if ever found first.
cat > "$TMP/shim/git" <<'SHIM'
#!/bin/sh
echo "PWNED-SHIM-GIT"
SHIM
chmod +x "$TMP/shim/git"
# A poisoned HOME with a Python user-site sitecustomize (the exact HOME-based RCE the
# wrapper must defeat by re-deriving HOME from the password database). Target the actual
# python3 version's user-site dir so the negative test is valid on any interpreter.
_pyver=$(python3 -c 'import sys; print("python%d.%d" % sys.version_info[:2])' 2>/dev/null || echo python3)
_usersite="$TMP/evil_home/.local/lib/$_pyver/site-packages"
mkdir -p "$_usersite"
printf 'open("%s","w").close()\n' "$TMP/SITECUSTOMIZE_RAN" > "$_usersite/sitecustomize.py"

# ── Run the probe through the EXACT hooks.json invocation, env fully poisoned ─
# Outer shell exports the levers a committed settings.json `env` block would set:
# SKIP_LITMUS, BASH_ENV, a PATH with the shim dir first, an exported git function,
# and a BUSDRIVER_STATE_DIR override.
run_out="$(
  # shellcheck disable=SC2329  # invoked indirectly via `export -f`, then stripped by env -i
  git() { echo "PWNED-FUNC-GIT"; }
  export -f git
  export SKIP_LITMUS=1
  export BASH_ENV="$TMP/evil.sh"
  export BUSDRIVER_STATE_DIR="attacker-dir"
  export PATH="$TMP/shim:$PATH"
  export HOME="$TMP/evil_home"
  /usr/bin/env -i \
    PATH=/usr/bin:/bin \
    HOME="$TMP/evil_home" \
    CLAUDE_PLUGIN_ROOT="$TMP/root" \
    bash "$TMP/root/hooks/gate-scripts/lib/sanitized-gate.sh" _probe.sh 2>&1
)"

echo "--- probe saw ---"
echo "$run_out"
echo "-----------------"

# ── Assertions ──────────────────────────────────────────────────────────────
grep -q 'SKIP_LITMUS=\[\]'  <<<"$run_out"; assert $? "SKIP_LITMUS stripped"
grep -q 'BASH_ENV=\[\]'     <<<"$run_out"; assert $? "BASH_ENV stripped"
assert_true test ! -e "$TMP/BASH_ENV_RAN"  "BASH_ENV code never ran"
! grep -q 'PWNED'           <<<"$run_out"; assert $? "git not hijacked (no shim/function)"
! grep -q "$TMP/shim"       <<<"$run_out"; assert $? "PATH shim dir stripped"
grep -q 'STATE_DIR=\[\]'    <<<"$run_out"; assert $? "BUSDRIVER_STATE_DIR override stripped (gate defaults to .claude)"
! grep -q "evil_home"       <<<"$run_out"; assert $? "poisoned HOME overridden (re-derived from passwd, not the env)"
assert_true test ! -e "$TMP/SITECUSTOMIZE_RAN" "poisoned ~/.local sitecustomize.py never ran (HOME re-derived + PYTHONNOUSERSITE)"
grep -q 'PYTHONNOUSERSITE=\[1\]' <<<"$run_out"; assert $? "PYTHONNOUSERSITE=1 set (Python user-site disabled)"

# ── Task 3: end-to-end node-hook containment ────────────────────────────────
# Run the EXACT hooks.json invocation for the block-no-verify node hook against
# the REAL runner + hook, from a poisoned shell that (a) injects the profile flag
# a committed settings.json would use to DISABLE the hook, and (b) removes node
# from /usr/bin:/bin. Proves node-resolution (trusted PATH rebuild) + flag-wipe
# (env -i) together: the commit-hook-bypass is STILL blocked (exit 2).
NODE_WRAPPER="$REPO_ROOT/hooks/gate-scripts/lib/sanitized-node.sh"
# The commit string is assembled here (not in any Claude Bash call) so the live
# block-no-verify hook doesn't trip on this file's own runner text.
_bypass_cmd="git commit $(printf -- '--no-verify') -m x"
_payload=$(printf '{"tool":"Bash","tool_input":{"command":"%s"}}' "$_bypass_cmd")

# The profile-disable flags are injected as command-prefix assignments on the parent of
# `env -i` (which then wipes them) — the whole point being that env -i strips the
# PR-injected ECC_HOOK_PROFILE / ECC_DISABLED_HOOKS so the hook runs default-enabled.
blk_out="$(
  printf '%s' "$_payload" | ECC_HOOK_PROFILE=minimal ECC_DISABLED_HOOKS="pre:bash:block-no-verify" /usr/bin/env -i \
    PATH=/usr/bin:/bin \
    HOME="$REAL_HOME" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
    bash "$NODE_WRAPPER" "pre:bash:block-no-verify" "scripts/hooks/block-no-verify.js" "standard,strict" 2>&1
)"
blk_rc=$?
echo "--- block-no-verify (contained) saw ---"; echo "$blk_out"; echo "  rc=$blk_rc"; echo "---"
assert_true test "$blk_rc" -eq 2      "commit-bypass still BLOCKED (exit 2) despite ECC_HOOK_PROFILE=minimal + node off /usr/bin:/bin"
grep -qi 'BLOCKED'        <<<"$blk_out";  assert $? "block reason reached stderr"
! grep -qi 'node not found\|runtime unavailable' <<<"$blk_out"; assert $? "node resolved via trusted PATH (no fail-closed launch fallback needed)"

# Relative CLAUDE_PLUGIN_ROOT (manual/local setups): the wrapper normalizes root to absolute
# BEFORE cd /, so $runner + hook path survive the neutral cwd and the gate still fires.
relroot_rc=0
( cd "$REPO_ROOT" && printf '%s' "$_payload" | /usr/bin/env -i \
    PATH=/usr/bin:/bin HOME="$REAL_HOME" CLAUDE_PLUGIN_ROOT="." CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
    bash "$NODE_WRAPPER" "pre:bash:block-no-verify" "scripts/hooks/block-no-verify.js" "standard,strict" ) >/dev/null 2>&1 || relroot_rc=$?
assert_true test "$relroot_rc" -eq 2 "relative CLAUDE_PLUGIN_ROOT normalized to absolute → gate still BLOCKS through cd /"

# Fail-CLOSED launch: if node/runner cannot be found, the wrapper blocks (exit 2),
# never passes through. Simulate by pointing CLAUDE_PLUGIN_ROOT at a nonexistent
# root so the runner (run-with-flags.js) is missing — the _block path must fire.
nolaunch_out="$(
  printf '%s' "$_payload" | /usr/bin/env -i \
    PATH=/usr/bin:/bin \
    HOME="$REAL_HOME" \
    CLAUDE_PLUGIN_ROOT="$TMP/nonexistent-root" \
    CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
    bash "$NODE_WRAPPER" "pre:bash:block-no-verify" "scripts/hooks/block-no-verify.js" "standard,strict" 2>&1
)"
nolaunch_rc=$?
assert_true test "$nolaunch_rc" -eq 2 "missing runner fails CLOSED (exit 2), never passes through"
grep -q '"decision":"block"' <<<"$nolaunch_out"; assert $? "fail-closed path emits block decision"

# Runner CRASH (node runs but the runner exits non-0/non-2): the wrapper must NOT
# forward that exit (which the harness would treat as a non-blocking error → tool
# proceeds) but convert it to a fail-CLOSED block (exit 2). Fake a root whose runner
# exits 127.
mkdir -p "$TMP/crashroot/scripts/hooks"
printf 'process.exit(127);\n' > "$TMP/crashroot/scripts/hooks/run-with-flags.js"
# The wrapper's hook-script existence check runs BEFORE the runner; the target script
# must exist under crashroot or the wrapper blocks there and never reaches the fake
# runner — so the exit-127 conversion would go untested.
: > "$TMP/crashroot/scripts/hooks/block-no-verify.js"
crash_out="$(
  printf '%s' "$_payload" | /usr/bin/env -i \
    PATH=/usr/bin:/bin \
    HOME="$REAL_HOME" \
    CLAUDE_PLUGIN_ROOT="$TMP/crashroot" \
    CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
    bash "$NODE_WRAPPER" "pre:bash:block-no-verify" "scripts/hooks/block-no-verify.js" "standard,strict" 2>&1
)"
crash_rc=$?
assert_true test "$crash_rc" -eq 2 "runner crash (exit 127) converted to fail-CLOSED block (exit 2), not forwarded"
grep -q '"decision":"block"' <<<"$crash_out"; assert $? "crash path emits block decision"

# Registration-level fail-CLOSED: if bash cannot even launch the wrapper (missing file
# / bad CLAUDE_PLUGIN_ROOT), the outer command exits 127 BEFORE the wrapper runs. The
# trailing `|| exit 2` in the hooks.json registration must convert that to a block.
# Run the EXACT outer shape against a nonexistent wrapper path.
/usr/bin/env -i PATH=/usr/bin:/bin HOME="$REAL_HOME" \
    bash "$TMP/does-not-exist/sanitized-node.sh" "pre:bash:block-no-verify" x y </dev/null >/dev/null 2>&1 || launch_rc=$?
assert_true test "${launch_rc:-0}" -ne 0 "bash cannot launch a missing wrapper (non-zero, pre-|| baseline)"
# Now with the registration's `|| exit 2` tail:
( /usr/bin/env -i PATH=/usr/bin:/bin HOME="$REAL_HOME" \
    bash "$TMP/does-not-exist/sanitized-node.sh" "pre:bash:block-no-verify" x y </dev/null >/dev/null 2>&1 || exit 2 )
guard_rc=$?
assert_true test "$guard_rc" -eq 2 "missing-wrapper launch failure → registration '|| exit 2' blocks (fail-CLOSED)"

# Missing HOOK SCRIPT: run-with-flags.js fail-OPENs (exit 0) when the dispatched hook
# script is absent; the wrapper must catch that and fail CLOSED. Point it at a hook
# path that does not exist under the real repo root.
missing_out="$(
  printf '%s' "$_payload" | /usr/bin/env -i \
    PATH=/usr/bin:/bin \
    HOME="$REAL_HOME" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
    CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
    bash "$NODE_WRAPPER" "pre:bash:block-no-verify" "scripts/hooks/does-not-exist.js" "standard,strict" 2>&1
)"
missing_rc=$?
assert_true test "$missing_rc" -eq 2 "missing hook script → wrapper fails CLOSED (exit 2), not run-with-flags' exit-0 allow"
grep -q '"decision":"block"' <<<"$missing_out"; assert $? "missing-hook-script path emits block decision"
# And a traversal/absolute hook path is refused, not dispatched.
trav_rc=0
printf '%s' "$_payload" | /usr/bin/env -i PATH=/usr/bin:/bin HOME="$REAL_HOME" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
    bash "$NODE_WRAPPER" "pre:bash:block-no-verify" "../../etc/passwd" "standard,strict" >/dev/null 2>&1 || trav_rc=$?
assert_true test "$trav_rc" -eq 2 "traversal hook path refused (fail-CLOSED exit 2)"
# Empty script arg (malformed registration): must fail CLOSED, not dispatch into
# run-with-flags' empty-arg exit-0 allow.
empty_rc=0
printf '%s' "$_payload" | /usr/bin/env -i PATH=/usr/bin:/bin HOME="$REAL_HOME" \
    CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
    bash "$NODE_WRAPPER" "pre:bash:block-no-verify" "" "standard,strict" >/dev/null 2>&1 || empty_rc=$?
assert_true test "$empty_rc" -eq 2 "empty hook script arg → fail CLOSED (exit 2)"

# Node preference + validation (Codex P2): the wrapper must prefer an operator-managed
# node over a stale system node, and SKIP a candidate whose `node --check <runner>` fails
# (a node too old to PARSE the runner, which a bare `--version` would not catch). The
# wrapper re-derives HOME from passwd (so a fake ~/.nvm can't be injected through env),
# hence exercise the exact resolution loop standalone: an early candidate that fails
# --check must be skipped for a later one that passes.
_prefer=$(bash -c '
  set -euo pipefail
  TMP=$(mktemp -d)
  mkdir -p "$TMP/oldnode" "$TMP/goodnode"
  # oldnode: exits nonzero on `--check` (models a node too old to parse the runner)
  printf "#!/bin/sh\nexit 1\n" > "$TMP/oldnode/node"; chmod +x "$TMP/oldnode/node"
  # goodnode: `--check` succeeds
  printf "#!/bin/sh\nexit 0\n" > "$TMP/goodnode/node"; chmod +x "$TMP/goodnode/node"
  runner="$TMP/runner.js"; : > "$runner"
  _node=""; _node_cands=("$TMP/oldnode" "$TMP/goodnode" /usr/bin /bin)
  for _cand in "${_node_cands[@]}"; do
    [[ -n "$_cand" && -x "$_cand/node" ]] || continue
    "$_cand/node" --check "$runner" >/dev/null 2>&1 || continue
    _node="$_cand/node"; break
  done
  case "$_node" in *"/goodnode/node") echo OK ;; *) echo "BAD:$_node" ;; esac
  rm -rf "$TMP"
')
assert_true test "$_prefer" = "OK" "node resolution skips a candidate that fails --check <runner> for one that passes"
# Tie the test to the PRODUCTION wrapper (guards against the loop/validation being
# removed or weakened): the real file must validate with `--check "$runner"` (not a bare
# --version) and must build the candidate list operator-dirs (_uds) BEFORE system dirs.
# shellcheck disable=SC2016  # grepping for the LITERAL string --check "$runner" in the wrapper
grep -q -- '--check "$runner"' "$NODE_WRAPPER"; assert $? "wrapper validates node with --check against the runner (not --version)"
# Node candidates: system dirs first, then passwd-HOME direct-binary fallback (~/.local/bin
# + nvm version bins) so an nvm-only host resolves. Shims (Volta/asdf/mise) and shared
# prefixes (Linuxbrew) stay OUT of executed code (shim = repo-config indirection; shared =
# LCE surface). The cd / above makes the ~/.local/bin + nvm fallback shim-config-safe.
grep -qE '_cands=\(/opt/homebrew/bin /usr/local/bin /usr/bin /bin\)' "$NODE_WRAPPER"; assert $? "node candidate list starts with the trusted system dirs"
grep -qE '\.nvm/versions/node/\*/bin' "$NODE_WRAPPER"; assert $? "nvm version bins are searched as a passwd-HOME fallback (nvm-only host resolves)"
# (strip comment lines first — the rationale note legitimately names these dirs)
! grep -vE '^[[:space:]]*#' "$NODE_WRAPPER" | grep -qE '\.volta|\.asdf|mise/shims|linuxbrew'; assert $? "no version-manager shim dir or shared prefix in EXECUTED code (no shim-indirection / LCE surface)"
# The wrapper MUST neutralize CWD (cd /) before running node, so a system-dir node that is
# a symlink to a version-manager shim can't read repo-local config. Safe because
# config-protection resolves file_path against the PAYLOAD cwd (asserted below).
grep -qE '^[[:space:]]*cd / ' "$NODE_WRAPPER"; assert $? "wrapper neutralizes CWD (cd /) before running node"

# run() EXCEPTION: run-with-flags.js catches a hook's run() throw and would exit 0
# (fail-open). The `--fail-closed` ARG makes the runner convert it to exit 2. Exercise the
# REAL runner with a throwing hook under a temp plugin root. The signal is a positional
# arg (not an env var), so the without-arg case is unaffected by any ambient environment.
mkdir -p "$TMP/failroot/scripts/hooks"
printf 'module.exports = { run() { throw new Error("boom"); } };\n' > "$TMP/failroot/scripts/hooks/throwing.js"
REAL_RUNNER="$REPO_ROOT/scripts/hooks/run-with-flags.js"
fc_rc=0
printf '%s' "$_payload" | CLAUDE_PLUGIN_ROOT="$TMP/failroot" \
    node "$REAL_RUNNER" "pre:x" "scripts/hooks/throwing.js" "standard,strict" --fail-closed >/dev/null 2>&1 || fc_rc=$?
assert_true test "$fc_rc" -eq 2 "run() exception → exit 2 with the --fail-closed arg (fail-CLOSED)"
fo_rc=0
printf '%s' "$_payload" | CLAUDE_PLUGIN_ROOT="$TMP/failroot" \
    node "$REAL_RUNNER" "pre:x" "scripts/hooks/throwing.js" "standard,strict" >/dev/null 2>&1 || fo_rc=$?
assert_true test "$fo_rc" -eq 0 "run() exception → exit 0 WITHOUT the arg (unchanged for non-gate hooks)"
# Integration: the wrapper must actually pass --fail-closed to the runner (else the
# runner-honors-arg unit test above proves nothing about the real path).
grep -q -- '--fail-closed' "$NODE_WRAPPER"; assert $? "sanitized-node.sh passes --fail-closed to the runner"

# config-protection e2e: a Write to an EXISTING protected config, with the profile-flag
# injected, must still BLOCK under the sanitized wrapper.
: > "$TMP/.eslintrc"
_cfg_payload=$(printf '{"tool":"Write","tool_input":{"file_path":"%s/.eslintrc","content":"x"}}' "$TMP")
cfg_rc=0
printf '%s' "$_cfg_payload" | ECC_HOOK_PROFILE=minimal /usr/bin/env -i \
    PATH=/usr/bin:/bin HOME="$REAL_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
    bash "$NODE_WRAPPER" "pre:config-protection" "scripts/hooks/config-protection.js" "standard,strict" >/dev/null 2>&1 || cfg_rc=$?
assert_true test "$cfg_rc" -eq 2 "config-protection still BLOCKS a protected-file edit under sanitized env"

# config-protection with a RELATIVE file_path (Codex P1 regression guard): the wrapper runs
# node from a neutral cwd (/), so config-protection MUST resolve the relative path against
# the PAYLOAD cwd — an EXISTING protected config named relatively must still BLOCK, not slip
# through as a phantom ENOENT/allow.
mkdir -p "$TMP/proj"; : > "$TMP/proj/.eslintrc"
_cfg_rel=$(printf '{"cwd":"%s/proj","tool":"Write","tool_input":{"file_path":".eslintrc","content":"x"}}' "$TMP")
crel_rc=0
printf '%s' "$_cfg_rel" | /usr/bin/env -i \
    PATH=/usr/bin:/bin HOME="$REAL_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
    bash "$NODE_WRAPPER" "pre:config-protection" "scripts/hooks/config-protection.js" "standard,strict" >/dev/null 2>&1 || crel_rc=$?
assert_true test "$crel_rc" -eq 2 "config-protection resolves a RELATIVE file_path against payload cwd and still BLOCKS (neutral process cwd doesn't weaken it)"
# A relative protected path with NO payload cwd cannot be resolved → fail CLOSED (block).
_cfg_nocwd='{"tool":"Write","tool_input":{"file_path":".eslintrc","content":"x"}}'
cnc_rc=0
printf '%s' "$_cfg_nocwd" | /usr/bin/env -i \
    PATH=/usr/bin:/bin HOME="$REAL_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
    bash "$NODE_WRAPPER" "pre:config-protection" "scripts/hooks/config-protection.js" "standard,strict" >/dev/null 2>&1 || cnc_rc=$?
assert_true test "$cnc_rc" -eq 2 "config-protection fails CLOSED on an unresolvable relative protected path (no payload cwd)"
# A RELATIVE payload cwd (e.g. ".") is untrustworthy under the neutral process cwd → fail CLOSED.
_cfg_relcwd='{"cwd":".","tool":"Write","tool_input":{"file_path":".eslintrc","content":"x"}}'
crc_rc=0
printf '%s' "$_cfg_relcwd" | /usr/bin/env -i \
    PATH=/usr/bin:/bin HOME="$REAL_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
    bash "$NODE_WRAPPER" "pre:config-protection" "scripts/hooks/config-protection.js" "standard,strict" >/dev/null 2>&1 || crc_rc=$?
assert_true test "$crc_rc" -eq 2 "config-protection fails CLOSED when payload cwd is relative (untrustworthy under neutral cwd)"

# pre-bash-dev-server-block e2e: an un-tmux'd dev server, profile-flag injected, must BLOCK.
_dev_payload='{"tool":"Bash","tool_input":{"command":"npm run dev"}}'
dev_rc=0
printf '%s' "$_dev_payload" | ECC_HOOK_PROFILE=minimal /usr/bin/env -i \
    PATH=/usr/bin:/bin HOME="$REAL_HOME" CLAUDE_PLUGIN_ROOT="$REPO_ROOT" CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
    bash "$NODE_WRAPPER" "pre:bash:dev-server-block" "scripts/hooks/pre-bash-dev-server-block.js" "standard,strict" >/dev/null 2>&1 || dev_rc=$?
assert_true test "$dev_rc" -eq 2 "pre-bash-dev-server-block still BLOCKS an un-tmux'd dev server under sanitized env"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ALL CONTAINMENT ASSERTIONS PASSED"
