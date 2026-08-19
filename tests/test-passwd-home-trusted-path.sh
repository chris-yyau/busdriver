#!/usr/bin/env bash
# Test: passwd-HOME derivation must not be steerable by a user-writable PATH dir or
# by an imported shell function — issue #660.
#
# Both containment wrappers rebuild a fixed PATH allowlist whose first entries
# (/usr/local/bin, /opt/homebrew/bin) are OPERATOR-WRITABLE on a default Homebrew
# install, then shelled out to id/getent/dscl through it. macOS ships no `getent` at
# all, so a planted one is found with nothing to shadow and its stdout became HOME for
# every contained gate. A shell FUNCTION named `getent` outranks PATH the same way.
# Both are closed by deriving in a child under `/usr/bin/env -i`.
#
# The fixture cannot write /opt/homebrew/bin, so it SUBSTITUTES a writable plant dir
# into the copy's allowlist — a faithful stand-in for the writable entry already there.
# The function leg invokes the wrapper WITHOUT `env -i` on purpose: that makes it an
# assertion about the wrapper's own defense, not about its hooks.json launch line.
#
# Vacuous-pass guards: the decoy home EXISTS (the wrapper rejects a non-dir home and
# would fall through to the real one), the substitution is verified to have taken, and
# both plants are first shown to WORK against the pre-#660 derivation shape.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
assert() {
    if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi
}

# No `set -e` here (assertions rely on non-zero rc), so bail explicitly: an empty TMP
# would make every path below resolve at the filesystem root.
_user="$(/usr/bin/id -un)" || { echo "cannot resolve user" >&2; exit 1; }
REAL_HOME="$(eval echo "~$_user")"
[[ -n "$REAL_HOME" && -d "$REAL_HOME" ]] || { echo "cannot resolve real home" >&2; exit 1; }
TMP="$(mktemp -d)"
[[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PLANT="$TMP/writable_bin"
DECOY="$TMP/decoy_home"
mkdir -p "$PLANT" "$DECOY" "$TMP/root/hooks/gate-scripts/lib" "$TMP/root/scripts/hooks"

# A planted getent, as reachable from a writable PATH dir as a real one would be.
cat > "$PLANT/getent" <<PLANTED
#!/bin/sh
printf '%s:x:501:20::$DECOY:/bin/sh\n' "\$2"
PLANTED
chmod +x "$PLANT/getent"

# The pre-#660 derivation shape, used only to prove both plants actually work.
cat > "$TMP/vulnerable.sh" <<'VULN'
_u=$(id -un); _home=$(getent passwd "$_u" | cut -d: -f6)
echo "HOME=[$_home]"
VULN

# ── Controls: the plants steer the OLD shape ────────────────────────────────
ctl_path="$(PATH="$PLANT:$PATH" bash "$TMP/vulnerable.sh" 2>&1)"
grep -q "HOME=\[$DECOY\]" <<<"$ctl_path"
assert $? "control: a planted getent on a writable PATH dir DOES steer the pre-fix shape ($ctl_path)"

ctl_fn="$(
  # shellcheck disable=SC2329  # invoked indirectly via `export -f` in the bash child
  getent() { printf '%s:x:501:20::%s:/bin/sh\n' "$2" "$DECOY"; }
  export -f getent
  export DECOY            # the function body expands $DECOY in the CHILD
  bash "$TMP/vulnerable.sh" 2>&1
)"
grep -q "HOME=\[$DECOY\]" <<<"$ctl_fn"
assert $? "control: an exported getent() DOES steer the pre-fix shape ($ctl_fn)"

# ── Install each wrapper with the plant dir inside its PATH allowlist ───────
install_wrapper() {  # install_wrapper <src> <dest>
    sed "s|^for _d in /usr/local/bin|for _d in $PLANT /usr/local/bin|" "$1" > "$2"
    grep -q "for _d in $PLANT " "$2"   # fixture is live only if the substitution took
}

# ── Leg 0: the launch invariant the wrappers rely on ───────────────────────
# The sterile child closes PATH/command-name lookup, but an imported FUNCTION named
# `export`/`cd`/`exec` intercepts the wrapper wherever it runs and no in-script purge
# can help. That class is closed by `/usr/bin/env -i` at the launch, so every
# sanitized-gate.sh registration must actually use it. (test-node-hook-containment.sh
# already pins the same invariant for the node-hook registrations.)
_regs="$(grep 'sanitized-gate.sh' "$REPO_ROOT/hooks/hooks.json")"
_bad=0
_n=0
while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _n=$((_n+1))
    grep -qE '"command":[[:space:]]*"/usr/bin/env -i ' <<<"$_line" || _bad=1
done <<< "$_regs"
_rc=0
[[ "$_n" -ge 1 && "$_bad" -eq 0 ]] || _rc=1
assert "$_rc" "all $_n sanitized-gate.sh registrations launch under /usr/bin/env -i (strips BASH_FUNC_*)"

# ── Leg 1: sanitized-gate.sh ────────────────────────────────────────────────
cat > "$TMP/root/hooks/gate-scripts/_probe.sh" <<'PROBE'
echo "HOME=[${HOME:-}]"
PROBE
GATE_COPY="$TMP/root/hooks/gate-scripts/lib/sanitized-gate.sh"
install_wrapper "$REPO_ROOT/hooks/gate-scripts/lib/sanitized-gate.sh" "$GATE_COPY"
assert $? "fixture is live: plant dir substituted into sanitized-gate.sh's PATH allowlist"

gate_path_out="$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$DECOY" CLAUDE_PLUGIN_ROOT="$TMP/root" \
    bash "$GATE_COPY" _probe.sh 2>&1)"
grep -q "HOME=\[$REAL_HOME\]" <<<"$gate_path_out"
assert $? "sanitized-gate.sh: planted getent on the trusted PATH cannot supply HOME ($gate_path_out)"

gate_fn_out="$(
  # shellcheck disable=SC2329  # invoked indirectly via `export -f` in the bash child
  getent() { printf '%s:x:501:20::%s:/bin/sh\n' "$2" "$DECOY"; }
  export -f getent
  export DECOY            # the function body expands $DECOY in the CHILD
  HOME="$DECOY" CLAUDE_PLUGIN_ROOT="$TMP/root" bash "$GATE_COPY" _probe.sh 2>&1
)"
grep -q "HOME=\[$REAL_HOME\]" <<<"$gate_fn_out"
assert $? "sanitized-gate.sh: an exported getent() cannot supply HOME either ($gate_fn_out)"

# ── Leg 2: sanitized-node.sh ────────────────────────────────────────────────
# The wrapper hardcodes scripts/hooks/run-with-flags.js as the runner and verifies the
# named hook script exists, so the skeleton supplies both. The runner must parse under
# `node --check` (the wrapper's node-validation step).
cat > "$TMP/root/scripts/hooks/run-with-flags.js" <<'RUNNER'
console.log("HOME=[" + (process.env.HOME || "") + "]");
RUNNER
: > "$TMP/root/scripts/hooks/probe.js"
NODE_COPY="$TMP/root/hooks/gate-scripts/lib/sanitized-node.sh"
install_wrapper "$REPO_ROOT/hooks/gate-scripts/lib/sanitized-node.sh" "$NODE_COPY"
assert $? "fixture is live: plant dir substituted into sanitized-node.sh's PATH allowlist"

node_path_out="$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$DECOY" CLAUDE_PLUGIN_ROOT="$TMP/root" \
    CLAUDE_HOOK_EVENT_NAME=PreToolUse \
    bash "$NODE_COPY" "pre:probe" "scripts/hooks/probe.js" 2>&1)"
grep -q "HOME=\[$REAL_HOME\]" <<<"$node_path_out"
assert $? "sanitized-node.sh: contained hook inherits the real passwd HOME, not the planted one ($node_path_out)"

node_fn_out="$(
  # shellcheck disable=SC2329  # invoked indirectly via `export -f` in the bash child
  getent() { printf '%s:x:501:20::%s:/bin/sh\n' "$2" "$DECOY"; }
  export -f getent
  export DECOY            # the function body expands $DECOY in the CHILD
  HOME="$DECOY" CLAUDE_PLUGIN_ROOT="$TMP/root" CLAUDE_HOOK_EVENT_NAME=PreToolUse \
    bash "$NODE_COPY" "pre:probe" "scripts/hooks/probe.js" 2>&1
)"
grep -q "HOME=\[$REAL_HOME\]" <<<"$node_fn_out"
assert $? "sanitized-node.sh: an exported getent() cannot supply HOME either ($node_fn_out)"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ALL #660 PASSWD-HOME ASSERTIONS PASSED"
