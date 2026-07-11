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
WRAPPER="$REPO_ROOT/hooks/gate-scripts/lib/sanitized-gate.sh"
PASS=0
FAIL=0
assert() {  # assert <condition-result:0/1> <message>
    if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi
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
[[ ! -e "$TMP/BASH_ENV_RAN" ]];            assert $? "BASH_ENV code never ran"
! grep -q 'PWNED'           <<<"$run_out"; assert $? "git not hijacked (no shim/function)"
! grep -q "$TMP/shim"       <<<"$run_out"; assert $? "PATH shim dir stripped"
grep -q 'STATE_DIR=\[\]'    <<<"$run_out"; assert $? "BUSDRIVER_STATE_DIR override stripped (gate defaults to .claude)"
! grep -q "evil_home"       <<<"$run_out"; assert $? "poisoned HOME overridden (re-derived from passwd, not the env)"
[[ ! -e "$TMP/SITECUSTOMIZE_RAN" ]];       assert $? "poisoned ~/.local sitecustomize.py never ran (HOME re-derived + PYTHONNOUSERSITE)"
grep -q 'PYTHONNOUSERSITE=\[1\]' <<<"$run_out"; assert $? "PYTHONNOUSERSITE=1 set (Python user-site disabled)"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ALL CONTAINMENT ASSERTIONS PASSED"
